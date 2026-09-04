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
    public var defaultKind: DesktopWorkKind
    public var defaultProvider: String
    public var defaultModel: String

    public init(
        instructionReferences: [String] = [],
        knowledgeSourceIDs: [String] = [],
        skillIDs: [String] = [],
        defaultKind: DesktopWorkKind = .coding,
        defaultProvider: String = "Codex",
        defaultModel: String = "Use provider default"
    ) {
        self.instructionReferences = instructionReferences
        self.knowledgeSourceIDs = knowledgeSourceIDs
        self.skillIDs = skillIDs
        self.defaultKind = defaultKind
        self.defaultProvider = defaultProvider
        self.defaultModel = defaultModel
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

public struct DesktopAppSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = KanameDesktopStateSchema.currentVersion

    public var version: Int
    public var projects: [DesktopProject]
    public var threads: [DesktopThread]
    public var remote: DesktopRemoteStatus
    public var preferences: DesktopPreferences
    public var domains: DesktopDomainSnapshot
    public var operations: DesktopOperationalSnapshot
    public var lastSavedAtUnixMillis: Int64

    public init(
        version: Int,
        projects: [DesktopProject],
        threads: [DesktopThread],
        remote: DesktopRemoteStatus,
        preferences: DesktopPreferences,
        domains: DesktopDomainSnapshot,
        operations: DesktopOperationalSnapshot,
        lastSavedAtUnixMillis: Int64
    ) {
        (self.version, self.projects, self.threads) = (version, projects, threads)
        (self.remote, self.preferences, self.domains) = (remote, preferences, domains)
        self.operations = operations
        self.lastSavedAtUnixMillis = lastSavedAtUnixMillis
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case projects
        case threads
        case remote
        case preferences
        case domains
        case operations
        case lastSavedAtUnixMillis
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        projects = try container.decode([DesktopProject].self, forKey: .projects)
        threads = try container.decode([DesktopThread].self, forKey: .threads)
        remote = try container.decode(DesktopRemoteStatus.self, forKey: .remote)
        preferences = try container.decode(DesktopPreferences.self, forKey: .preferences)
        domains = try container.decodeIfPresent(DesktopDomainSnapshot.self, forKey: .domains) ?? .empty
        operations = try container.decodeIfPresent(DesktopOperationalSnapshot.self, forKey: .operations) ?? .empty
        lastSavedAtUnixMillis = try container.decode(Int64.self, forKey: .lastSavedAtUnixMillis)
    }

    public static func starter(now: Int64) -> DesktopAppSnapshot {
        let project = DesktopProject(
            id: "project-kaname",
            name: "Kaname",
            summary: "Local-first personal agent workspace",
            context: DesktopProjectContext(
                instructionReferences: ["AGENTS.md"],
                knowledgeSourceIDs: ["knowledge-coding-ade", "knowledge-kaname-repository"],
                skillIDs: ["skill-mori-review", "skill-obsidian"],
                defaultKind: .coding,
                defaultProvider: "Codex",
                defaultModel: "Use provider default"
            ),
            createdAtUnixMillis: now
        )
        return DesktopAppSnapshot(
            version: currentVersion,
            projects: [project],
            threads: [
                DesktopThread(
                    id: "thread-desktop-dogfood",
                    projectID: project.id,
                    title: "Starter · Kaname desktop dogfood",
                    summary: "Starter context only. Workspace qualification has not run in this fresh state.",
                    kind: .coding,
                    attention: .needsResponse,
                    provider: "Codex",
                    model: "Use provider default",
                    updatedAtUnixMillis: now,
                    unread: true,
                    messages: [
                        DesktopMessage(
                            id: "message-desktop-brief",
                            role: .user,
                            body: "Build a polished desktop app that can become the primary place to work on Kaname.",
                            createdAtUnixMillis: now - 2_000
                        ),
                        DesktopMessage(
                            id: "message-desktop-ready",
                            role: .assistant,
                            body: "This starter describes the intended foundation. It is not an operational receipt; build, test, packaging, and visual qualification are unknown until run.",
                            createdAtUnixMillis: now - 1_000
                        ),
                    ],
                    plan: [
                        DesktopPlanItem(title: "Verify the persistent desktop foundation", state: .pending),
                        DesktopPlanItem(title: "Verify devices and remote health", state: .pending),
                        DesktopPlanItem(title: "Run packaging and interactive QA", state: .pending),
                    ],
                    evidence: [
                        DesktopEvidence(label: "Swift tests", detail: "Not run for this workspace state", state: .notRun),
                        DesktopEvidence(label: "Rust tests", detail: "Not run for this workspace state", state: .notRun),
                        DesktopEvidence(label: "Packaged app", detail: "Signing, installation, and visual qualification not run", state: .notRun),
                        DesktopEvidence(label: "Local core", detail: "Replay and transport qualification not run", state: .notRun),
                    ]
                ),
                DesktopThread(
                    id: "thread-phase3-mobile",
                    projectID: project.id,
                    title: "Starter · Mobile qualification",
                    summary: "Remote and mobile foundations are available; qualification has not run in this fresh state.",
                    kind: .planning,
                    attention: .needsResponse,
                    provider: "Kaname",
                    model: "External input required",
                    updatedAtUnixMillis: now - 60_000,
                    unread: true,
                    messages: [
                        DesktopMessage(
                            id: "message-phase3-boundary",
                            role: .system,
                            body: "Physical-device and paid-team APNs evidence remain deferred. The connected charging iPhone is excluded.",
                            createdAtUnixMillis: now - 60_000
                        ),
                    ],
                    evidence: [
                        DesktopEvidence(label: "Hosted relay", detail: "Not run; remote state is unknown", state: .notRun),
                        DesktopEvidence(label: "Simulator recovery", detail: "Not run for this workspace state", state: .notRun),
                        DesktopEvidence(label: "Physical device", detail: "Not run; explicitly deferred", state: .notRun),
                    ]
                ),
                DesktopThread(
                    id: "thread-local-core",
                    projectID: project.id,
                    title: "Starter · Local authority health",
                    summary: "Local-core foundations are configured; current health and qualification are unknown.",
                    kind: .coding,
                    attention: .needsInput,
                    provider: "Kaname local core",
                    model: "Provider-free",
                    updatedAtUnixMillis: now - 120_000,
                    evidence: [
                        DesktopEvidence(label: "Local core", detail: "Acceptance corpus not run for this workspace state", state: .notRun),
                        DesktopEvidence(label: "Codex adapter", detail: "Accepted workflow not run for this workspace state", state: .notRun),
                    ]
                ),
            ],
            remote: .unverifiedFoundation(),
            preferences: DesktopPreferences(),
            domains: .starter(now: now),
            operations: .empty,
            lastSavedAtUnixMillis: now
        )
    }

    func migratedToCurrent(now: Int64) throws -> DesktopAppSnapshot {
        guard (1..<Self.currentVersion).contains(version) else { throw DesktopModelError.unsupportedVersion }
        var migrated = self
        while migrated.version < Self.currentVersion {
            switch migrated.version {
            case 1:
                break
            case 2:
                if migrated.domains == .empty {
                    migrated.domains = .starter(now: now)
                }
            case 3, 4, 5:
                break
            case 6:
                if let index = migrated.projects.firstIndex(where: { $0.id == "project-kaname" }),
                   migrated.projects[index].context == .empty {
                    migrated.projects[index].context = DesktopProjectContext(
                        instructionReferences: ["AGENTS.md"],
                        knowledgeSourceIDs: ["knowledge-coding-ade", "knowledge-kaname-repository"],
                        skillIDs: ["skill-mori-review", "skill-obsidian"]
                    )
                }
            case 7, 8, 9, 10, 11, 12, 13:
                break
            case 14:
                let terminalRunIDs = Set(migrated.operations.providerRuns.compactMap { run in
                    switch run.state {
                    case .completed, .failed, .interrupted, .rejected, .cancelled:
                        run.id
                    case .proposed, .awaitingApproval, .approved, .running, .reconciled:
                        nil
                    }
                })
                migrated.operations.providerEvents.removeAll { event in
                    terminalRunIDs.contains(event.runID)
                        && (event.kind == .assistantText || event.kind == .native)
                }
                for index in migrated.operations.providerEvents.indices
                    where terminalRunIDs.contains(migrated.operations.providerEvents[index].runID) {
                    migrated.operations.providerEvents[index].rawPayloadBase64 = nil
                }
            case 15:
                for index in migrated.threads.indices {
                    migrated.threads[index].createdAtUnixMillis = migrated.threads[index].messages
                        .map(\.createdAtUnixMillis)
                        .min() ?? migrated.threads[index].updatedAtUnixMillis
                }
            case 16:
                // Workflow state decodes to an empty collection for older snapshots.
                // Advancing the schema prevents an older build from silently
                // discarding workflow history after it has been created.
                break
            case 17:
                // Capability receipts and runtime leases are additive. Built-in
                // capabilities are regenerated from this exact Kaname build;
                // imported/private capabilities remain explicit installations.
                if migrated.operations.workflows.capabilityInstallations.isEmpty {
                    migrated.operations.workflows.capabilityInstallations =
                        DesktopWorkflowBuiltinCapabilities.installations(at: now)
                }
                migrated.operations.workflows.runtimeClaims.removeAll()
            case 18:
                // Artifact roles, schema-validated state, and reviewed knowledge
                // decode additively. A new schema prevents older builds from
                // silently discarding their durable workflow data plane.
                break
            case 19:
                // Typed graph decisions, structured reviews, resumable waits,
                // datasets, connector previews, authority grants, and bounded
                // execution evidence decode additively into the workflow host.
                break
            case 20:
                // Production mail reads, connector effects, and bounded agent
                // execution are built-in host capabilities. Merge them by ID so
                // existing installations gain the new host surface without
                // replacing private or explicitly configured capabilities.
                let installedIDs = Set(
                    migrated.operations.workflows.capabilityInstallations.map(\.capabilityID)
                )
                migrated.operations.workflows.capabilityInstallations.append(
                    contentsOf: DesktopWorkflowBuiltinCapabilities.installations(at: now)
                        .filter { !installedIDs.contains($0.capabilityID) }
                )
            case 21:
                // Trigger health, ownership, extension bindings, reusable
                // components, schedules, and migration evidence are additive.
                // They intentionally start empty so older workspaces do not
                // silently gain observation or effect authority.
                break
            case 22:
                // Manifest-v3 installation, configuration, binding, dependency,
                // capture, and retention revisions decode additively. Existing
                // definitions retain their legacy behavior and gain no new
                // observation, secret, or effect authority during migration.
                break
            case 23:
                // Studio presentation metadata, typed mappings, undo history,
                // and durable batch items decode additively. No graph is
                // rewritten and no execution or effect authority is granted.
                break
            case 24:
                // Authority history, content lifecycle receipts, and quiet
                // operational status decode additively. Existing grants retain
                // their exact scope and no captured content is purged during
                // migration.
                break
            case 25:
                // Signed-template verification, deterministic workflow
                // simulation, exact dependency locks on runs, and
                // revision-bound migration comparisons decode additively.
                // Existing workflows gain no authority or migration evidence.
                break
            case 26:
                // Coding workflow and knowledge-lane records decode additively.
                // Existing conversations gain no implementation, acceptance,
                // or knowledge-write authority during migration.
                break
            case 27:
                // Remove only the exact legacy starter signatures that looked
                // like current acceptance receipts. User-created, edited, and
                // independently recorded evidence is preserved byte-for-byte.
                migrated.normalizeLegacyStarterClaims()
                // Application turns are owned by Kaname and remain stable
                // across provider retries and coding workflow phases. Native
                // provider turn IDs are intentionally not used for backfill.
                for index in migrated.operations.providerRuns.indices {
                    let run = migrated.operations.providerRuns[index]
                    if let sourceMessageID = run.sourceMessageID {
                        guard let threadID = run.threadID,
                              migrated.threads.first(where: { $0.id == threadID })?.messages.contains(where: {
                                  $0.id == sourceMessageID && $0.role == .user
                              }) == true else {
                            throw DesktopModelError.invalidState
                        }
                    }
                    migrated.operations.providerRuns[index].turnID = run.sourceMessageID ?? run.id
                }
                var runIdentities: [String: (turnID: String, threadID: String?)] = [:]
                for run in migrated.operations.providerRuns {
                    let identity = (turnID: run.turnID, threadID: run.threadID)
                    guard runIdentities.updateValue(identity, forKey: run.id) == nil else {
                        throw DesktopModelError.invalidState
                    }
                }
                for index in migrated.operations.providerEvents.indices {
                    let event = migrated.operations.providerEvents[index]
                    guard let identity = runIdentities[event.runID],
                          identity.threadID == event.threadID else {
                        throw DesktopModelError.invalidState
                    }
                    migrated.operations.providerEvents[index].turnID = identity.turnID
                }
                for threadIndex in migrated.threads.indices {
                    let containingThreadID = migrated.threads[threadIndex].id
                    migrated.threads[threadIndex].messages = try migrated.threads[threadIndex].messages.map { message in
                        let turnID: String?
                        switch message.role {
                        case .user:
                            turnID = message.id
                        case .assistant:
                            let prefix = "assistant-"
                            let runID = message.id.hasPrefix(prefix)
                                ? String(message.id.dropFirst(prefix.count))
                                : nil
                            if let runID {
                                guard let identity = runIdentities[runID],
                                      identity.threadID == containingThreadID else {
                                    throw DesktopModelError.invalidState
                                }
                                turnID = identity.turnID
                            } else {
                                turnID = nil
                            }
                        case .system:
                            turnID = nil
                        }
                        return DesktopMessage(
                            id: message.id,
                            turnID: turnID,
                            role: message.role,
                            body: message.body,
                            attachments: message.attachments,
                            createdAtUnixMillis: message.createdAtUnixMillis
                        )
                    }
                }
            default:
                throw DesktopModelError.unsupportedVersion
            }
            migrated.version += 1
        }
        return migrated
    }

    private mutating func normalizeLegacyStarterClaims() {
        if let index = threads.firstIndex(where: { $0.id == "thread-desktop-dogfood" }) {
            if threads[index].title == "Kaname desktop dogfood" {
                threads[index].title = "Starter · Kaname desktop dogfood"
            }
            if threads[index].summary == "The polished desktop workspace is installed and ready for dogfooding." {
                threads[index].summary = "Starter context only. Workspace qualification has not run in this fresh state."
            }
            for messageIndex in threads[index].messages.indices
                where threads[index].messages[messageIndex].id == "message-desktop-ready"
                    && threads[index].messages[messageIndex].body == "The persistent workspace, integrated safety surfaces, private local core, release packaging, and visual qualification are ready." {
                let legacyMessage = threads[index].messages[messageIndex]
                threads[index].messages[messageIndex] = DesktopMessage(
                    id: legacyMessage.id,
                    role: legacyMessage.role,
                    body: "This starter describes the intended foundation. It is not an operational receipt; build, test, packaging, and visual qualification are unknown until run.",
                    attachments: legacyMessage.attachments,
                    createdAtUnixMillis: legacyMessage.createdAtUnixMillis
                )
            }
            let legacyPlans: [String: String] = [
                "Persistent desktop workspace": "Verify the persistent desktop foundation",
                "Integrated devices and remote health": "Verify devices and remote health",
                "Packaging and interactive QA": "Run packaging and interactive QA",
            ]
            for planIndex in threads[index].plan.indices {
                let item = threads[index].plan[planIndex]
                if item.state == .complete, let replacement = legacyPlans[item.title] {
                    threads[index].plan[planIndex].title = replacement
                    threads[index].plan[planIndex].state = .pending
                }
            }
            let legacyEvidence: [String: (String, String)] = [
                "Full desktop suite passed": ("Swift tests", "Not run for this workspace state"),
                "26 tests passed": ("Rust tests", "Not run for this workspace state"),
                "Signed, installed, and visually qualified": ("Packaged app", "Signing, installation, and visual qualification not run"),
                "F-01 through F-14 replayed through Mach XPC": ("Local core", "Replay and transport qualification not run"),
            ]
            for evidenceIndex in threads[index].evidence.indices {
                let evidence = threads[index].evidence[evidenceIndex]
                if evidence.state == .passed,
                   let replacement = legacyEvidence[evidence.detail],
                   evidence.label == replacement.0 {
                    threads[index].evidence[evidenceIndex].detail = replacement.1
                    threads[index].evidence[evidenceIndex].state = .notRun
                }
            }
        }

        if let index = threads.firstIndex(where: { $0.id == "thread-phase3-mobile" }) {
            if threads[index].title == "Phase 3 mobile qualification" {
                threads[index].title = "Starter · Mobile qualification"
            }
            if threads[index].summary == "Simulator, hosted relay, reconciliation, recovery, and cleanup are complete." {
                threads[index].summary = "Remote and mobile foundations are available; qualification has not run in this fresh state."
            }
            let replacements: [String: String] = [
                "Clean after bounded qualification": "Not run; remote state is unknown",
                "Restart and reconciliation passed": "Not run for this workspace state",
                "Explicitly deferred": "Not run; explicitly deferred",
            ]
            for evidenceIndex in threads[index].evidence.indices {
                let evidence = threads[index].evidence[evidenceIndex]
                if let replacement = replacements[evidence.detail] {
                    threads[index].evidence[evidenceIndex].detail = replacement
                    threads[index].evidence[evidenceIndex].state = .notRun
                }
            }
        }

        if let index = threads.firstIndex(where: { $0.id == "thread-local-core" }) {
            if threads[index].title == "Local authority health" {
                threads[index].title = "Starter · Local authority health"
            }
            if threads[index].summary == "Signed XPC and durable Rust journal evidence remain available for inspection." {
                threads[index].summary = "Local-core foundations are configured; current health and qualification are unknown."
            }
            let replacements: [String: String] = [
                "Phase 1 acceptance corpus passed": "Acceptance corpus not run for this workspace state",
                "Phase 2 accepted workflow passed": "Accepted workflow not run for this workspace state",
            ]
            var replacedEvidence = false
            for evidenceIndex in threads[index].evidence.indices {
                let evidence = threads[index].evidence[evidenceIndex]
                if evidence.state == .passed, let replacement = replacements[evidence.detail] {
                    threads[index].evidence[evidenceIndex].detail = replacement
                    threads[index].evidence[evidenceIndex].state = .notRun
                    replacedEvidence = true
                }
            }
            if replacedEvidence, threads[index].attention == .completed {
                threads[index].attention = .needsInput
            }
        }

        let legacyRemoteEvents = [
            ("remote-relay-rehearsal", "Encrypted relay rehearsal", "Enrollment, edited queue, receipts, stale approval, rotation, revocation, and cleanup passed.", DesktopRemoteEvent.State.passed),
            ("remote-restart-recovery", "Restart recovery", "Enrollment, key custody, queue, receipts, history, and pending rotation recover safely.", DesktopRemoteEvent.State.passed),
            ("remote-apns-contract", "APNs payload contract", "Only a generic content-free attention hint is sent; encrypted work remains in the relay.", DesktopRemoteEvent.State.passed),
            ("remote-physical-iphone", "Physical iPhone qualification", "Deferred until a different iPhone is explicitly designated.", DesktopRemoteEvent.State.deferred),
        ]
        let hasExactLegacyRemote = remote.relayStatus == "Hosted relay clean"
            && remote.enrollmentStatus == "Simulator qualified · physical device deferred"
            && remote.notificationStatus == "Privacy contract passed · APNs credentials deferred"
            && remote.queueStatus == "Restart-safe · 0 pending after terminal receipts"
            && remote.events.count == legacyRemoteEvents.count
            && zip(remote.events, legacyRemoteEvents).allSatisfy { pair in
                let (event, expected) = pair
                return event.id == expected.0 && event.title == expected.1
                    && event.detail == expected.2 && event.state == expected.3
            }
        if hasExactLegacyRemote {
            remote = .unverifiedFoundation()
        }

        for index in operations.workflows.capabilityInstallations.indices {
            let capability = operations.workflows.capabilityInstallations[index]
            if DesktopWorkflowBuiltinCapabilities.identifiers.contains(capability.capabilityID),
               capability.runtime == .builtIn,
               capability.trust == .kanameBuiltIn,
               capability.lastTestPassed,
               capability.lastTestedAtUnixMillis == capability.installedAtUnixMillis {
                operations.workflows.capabilityInstallations[index].lastTestedAtUnixMillis = nil
                operations.workflows.capabilityInstallations[index].lastTestPassed = false
            }
        }
    }
}

extension DesktopAppSnapshot {
    @discardableResult
    mutating func attachWorkflowProviderLinkage(
        providerRunID: String,
        stepAttemptID: String,
        run: DesktopWorkflowRunRecord,
        attempt: DesktopWorkflowStepAttemptRecord
    ) -> Bool {
        changeTwoRecords(
            first: \.operations.providerRuns, id: providerRunID,
            change: { storedRun in
                storedRun.workflowWorkItemID = run.workItemID
                storedRun.workflowEpisodeID = run.episodeID
                storedRun.workflowRunID = run.id
                storedRun.workflowStepAttemptID = attempt.id
                storedRun.workflowContextSnapshotID = run.contextSnapshotID
            },
            second: \.operations.workflows.stepAttempts, id: stepAttemptID,
            change: { $0.providerRunID = providerRunID }
        )
    }

    mutating func appendWorkflowRecord<Record>(
        _ record: Record,
        at keyPath: WritableKeyPath<DesktopAppSnapshot, [Record]>,
        workItemID: String,
        workState: DesktopWorkflowWorkState? = nil,
        nextAction: String,
        updatedAtUnixMillis: Int64
    ) {
        self[keyPath: keyPath].append(record)
        setWorkflowWorkItemPresentation(
            id: workItemID, state: workState, nextAction: nextAction,
            updatedAtUnixMillis: updatedAtUnixMillis
        )
    }

    @discardableResult
    mutating func changeTwoRecords<First: Identifiable, Second: Identifiable>(
        first firstPath: WritableKeyPath<DesktopAppSnapshot, [First]>,
        id firstID: String,
        change firstChange: (inout First) -> Void,
        second secondPath: WritableKeyPath<DesktopAppSnapshot, [Second]>,
        id secondID: String,
        change secondChange: (inout Second) -> Void
    ) -> Bool where First.ID == String, Second.ID == String {
        guard changeRecord(at: firstPath, id: firstID, change: firstChange) else { return false }
        return changeRecord(at: secondPath, id: secondID, change: secondChange)
    }

    @discardableResult
    mutating func setWorkflowWorkItemPresentation(
        id: String,
        state: DesktopWorkflowWorkState? = nil,
        nextAction: String,
        updatedAtUnixMillis: Int64
    ) -> Bool {
        changeRecord(at: \.operations.workflows.workItems, id: id) { item in
            if let state { item.state = state }
            item.nextAction = nextAction
            item.updatedAtUnixMillis = updatedAtUnixMillis
        }
    }

    mutating func appendAudit(
        domain: String,
        action: String,
        target: String,
        state: DesktopActionState,
        detail: String,
        recordedAtUnixMillis: Int64
    ) {
        operations.audit.append(DesktopAuditRecord(
            id: UUID().uuidString.lowercased(), domain: domain, action: action,
            target: target, state: state, detail: detail,
            recordedAtUnixMillis: recordedAtUnixMillis
        ))
    }

    @discardableResult
    mutating func rebaselineWorkflowTrigger(id: String, at timestamp: Int64) -> Bool {
        guard changeRecord(
            at: \.operations.workflows.triggerBindings, id: id,
            change: { binding in
                binding.lastCursor = nil
                binding.updatedAtUnixMillis = timestamp
            }
        ) else { return false }
        _ = changeRecord(at: \.operations.workflows.triggerHealth, id: id) { health in
            health.state = .unknown
            health.nextAttemptAtUnixMillis = nil
            health.consecutiveFailures = 0
            health.errorCode = nil
            health.errorSummary = nil
            health.authenticationRequired = false
        }
        appendAudit(
            domain: "workflow-trigger", action: "rebaseline-requested", target: "binding:\(id)",
            state: .completed,
            detail: "The next trigger check will establish a new cursor without replaying existing remote items.",
            recordedAtUnixMillis: timestamp
        )
        return true
    }

    @discardableResult
    mutating func changeRecord<Record: Identifiable>(
        at keyPath: WritableKeyPath<DesktopAppSnapshot, [Record]>,
        id: String,
        change: (inout Record) -> Void
    ) -> Bool where Record.ID == String {
        guard let index = self[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { return false }
        change(&self[keyPath: keyPath][index])
        return true
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

private struct DesktopRecoveryWorkerState: Decodable {
    let processIdentifier: Int32
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

public final class FileDesktopStateStore: DesktopRecoveryStateStoring {
    public let fileURL: URL
    private let runtimeMoveItem: (URL, URL) throws -> Void

    public var recoveryFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("workspace.previous.json")
    }

    public var managedRecoveryDirectoryURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
    }

    public var backupHistoryDirectoryURL: URL {
        managedRecoveryDirectoryURL.appendingPathComponent("Backups", isDirectory: true)
    }

    public var quarantineDirectoryURL: URL {
        managedRecoveryDirectoryURL.appendingPathComponent("Quarantine", isDirectory: true)
    }

    public var receiptDirectoryURL: URL {
        managedRecoveryDirectoryURL.appendingPathComponent("Receipts", isDirectory: true)
    }

    public var recoveryLockMarkerURL: URL {
        managedRecoveryDirectoryURL.appendingPathComponent("runtime-recovery-lock.json")
    }

    public var applicationSupportRootURL: URL {
        fileURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    public var localCoreDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("LocalCore", isDirectory: true)
    }

    public var conversationServiceDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("ConversationService", isDirectory: true)
    }

    public var workflowInstallationsDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("WorkflowInstallations", isDirectory: true)
    }

    public var workflowCapabilitiesDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("WorkflowCapabilities", isDirectory: true)
    }

    public var workflowLibraryDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("Workflows", isDirectory: true)
    }

    public var workflowObjectsDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("Objects", isDirectory: true)
    }

    public var resetArchiveDirectoryURL: URL {
        managedRecoveryDirectoryURL.appendingPathComponent("ResetArchives", isDirectory: true)
    }

    public convenience init(fileURL: URL) {
        self.init(fileURL: fileURL) { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    init(
        fileURL: URL,
        runtimeMoveItem: @escaping (URL, URL) throws -> Void
    ) {
        self.fileURL = fileURL
        self.runtimeMoveItem = runtimeMoveItem
    }

    public static func applicationSupport(rootDirectoryName: String = "Kaname") -> FileDesktopStateStore {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return FileDesktopStateStore(
            fileURL: base
                .appendingPathComponent(rootDirectoryName, isDirectory: true)
                .appendingPathComponent("Desktop", isDirectory: true)
                .appendingPathComponent("workspace.json")
        )
    }

    public func load() throws -> Data? {
        try readPrivateIfPresent(at: fileURL)
    }

    public func save(_ data: Data) throws {
        try prepareDirectory()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard try DesktopRecoveryService.isRegularNonSymlink(fileURL) else { throw DesktopRecoveryError.unsafeSource }
            let previous = try Data(contentsOf: fileURL)
            try writePrivate(previous, to: recoveryFileURL)
        }
        try writePrivate(data, to: fileURL)
    }

    public func loadRecovery() throws -> Data? {
        try readPrivateIfPresent(at: recoveryFileURL)
    }

    public func saveRecovered(_ data: Data) throws {
        try prepareDirectory()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard try DesktopRecoveryService.isRegularNonSymlink(fileURL) else { throw DesktopRecoveryError.unsafeSource }
        }
        try writePrivate(data, to: fileURL)
    }

    @discardableResult
    public func quarantinePrimary(
        reasonCode: String,
        detectedAtUnixMillis: Int64
    ) throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard try DesktopRecoveryService.isRegularNonSymlink(fileURL) else { throw DesktopRecoveryError.unsafeSource }
        let primary = try Data(contentsOf: fileURL)
        try preparePrivateDirectory(quarantineDirectoryURL)
        let digest = DesktopRecoveryService.sha256(primary)
        let incidentURL = quarantineDirectoryURL.appendingPathComponent(
            "incident-\(digest.prefix(24))",
            isDirectory: true
        )
        let quarantinedStateURL = incidentURL.appendingPathComponent("workspace.json")
        if FileManager.default.fileExists(atPath: quarantinedStateURL.path) {
            guard DesktopRecoveryService.sha256(try Data(contentsOf: quarantinedStateURL)) == digest else {
                throw DesktopRecoveryError.destinationExists
            }
            return quarantinedStateURL
        }
        try preparePrivateDirectory(incidentURL)
        try writePrivate(primary, to: quarantinedStateURL)
        guard try Data(contentsOf: quarantinedStateURL) == primary else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
        let event = DesktopRedactedDiagnosticEvent(
            category: "persistence",
            code: reasonCode,
            occurredAtUnixMillis: detectedAtUnixMillis
        )
        try writePrivate(try recoveryEncoder.encode(event), to: incidentURL.appendingPathComponent("receipt.json"))
        return quarantinedStateURL
    }

    @discardableResult
    public func createPrivateBackupHistory(
        stateSchemaVersion: Int,
        createdAtUnixMillis: Int64,
        includesRuntimeState: Bool = false
    ) throws -> DesktopBackupManifest? {
        let sources = try recoverySources(includesRuntimeState: includesRuntimeState)
        guard !sources.isEmpty else { return nil }
        try preparePrivateDirectory(backupHistoryDirectoryURL)
        var sourceFingerprint = SHA256()
        for source in sources.sorted(by: { $0.archiveName < $1.archiveName }) {
            sourceFingerprint.update(data: Data(source.archiveName.utf8))
            sourceFingerprint.update(data: Data([0]))
            sourceFingerprint.update(data: try Data(contentsOf: source.fileURL, options: [.mappedIfSafe]))
        }
        let digest = sourceFingerprint.finalize().map { String(format: "%02x", $0) }.joined()
        let destination = backupHistoryDirectoryURL.appendingPathComponent(
            "backup-v\(stateSchemaVersion)-\(digest.prefix(24)).kanamebackup",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            return try DesktopRecoveryService().validateBackup(at: destination)
        }
        let service = DesktopRecoveryService()
        _ = try service.createBackup(
            at: destination,
            sources: sources,
            stateSchemaVersion: stateSchemaVersion,
            createdAtUnixMillis: createdAtUnixMillis,
            runtimeStateIncluded: includesRuntimeState
        )
        return try service.validateBackup(at: destination)
    }

    @discardableResult
    public func exportRecoveryBackup(
        to destination: URL,
        stateSchemaVersion: Int,
        createdAtUnixMillis: Int64
    ) throws -> DesktopBackupManifest {
        let runtimeLock = try acquireExclusiveRuntimeRecoveryLock()
        defer { _ = runtimeLock }
        try requireRuntimeQuiescent()
        let sources = try recoverySources(includesRuntimeState: true)
        let service = DesktopRecoveryService()
        _ = try service.createBackup(
            at: destination,
            sources: sources,
            stateSchemaVersion: stateSchemaVersion,
            createdAtUnixMillis: createdAtUnixMillis,
            runtimeStateIncluded: true
        )
        return try service.validateBackup(at: destination)
    }

    public func requireRuntimeQuiescent() throws {
        guard FileManager.default.fileExists(atPath: conversationServiceDirectoryURL.path) else { return }
        for url in try regularFiles(below: conversationServiceDirectoryURL)
        where url.lastPathComponent == "worker.json" {
            guard let data = try? Data(contentsOf: url),
                  let state = try? JSONDecoder().decode(DesktopRecoveryWorkerState.self, from: data),
                  state.processIdentifier > 1 else { continue }
#if os(macOS)
            if Darwin.kill(state.processIdentifier, 0) == 0 {
                throw DesktopModelRecoveryError.activeRuntimeWork
            }
#endif
        }
    }

    public func acquireExclusiveRuntimeRecoveryLock() throws -> KanameRuntimeRecoveryFileLock {
        do {
            return try KanameRuntimeRecoveryFileLock.acquireExclusiveNonblocking(
                applicationSupportRoot: applicationSupportRootURL
            )
        } catch {
            throw DesktopModelRecoveryError.activeRuntimeWork
        }
    }

    @discardableResult
    public func archiveRuntimeState(resetID: UUID) throws -> [DesktopRuntimeArchiveMove] {
        try requireRuntimeQuiescent()
        let destinationRoot = resetArchiveDirectoryURL
            .appendingPathComponent(resetID.uuidString.lowercased(), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destinationRoot.path) else {
            throw DesktopRecoveryError.destinationExists
        }
        try preparePrivateDirectory(destinationRoot)
        var moves: [DesktopRuntimeArchiveMove] = []
        do {
            for source in [
                localCoreDirectoryURL,
                conversationServiceDirectoryURL,
                workflowInstallationsDirectoryURL,
                workflowCapabilitiesDirectoryURL,
                workflowLibraryDirectoryURL,
                workflowObjectsDirectoryURL,
            ]
            where FileManager.default.fileExists(atPath: source.path) {
                let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw DesktopRecoveryError.unsafeSource
                }
                let destination = destinationRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                try runtimeMoveItem(source, destination)
                moves.append(.init(source: source, archive: destination))
            }
            return moves
        } catch {
            do {
                try restoreArchivedRuntimeState(moves)
            } catch {
                try? persistRecoveryFailureEvent(DesktopRedactedDiagnosticEvent(
                    category: "recovery",
                    code: "runtime-archive-rollback-unverified",
                    occurredAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
                ))
                throw DesktopModelRecoveryError.recoveryRollbackFailed
            }
            throw error
        }
    }

    public func restoreArchivedRuntimeState(_ moves: [DesktopRuntimeArchiveMove]) throws {
        for move in moves.reversed() where FileManager.default.fileExists(atPath: move.archive.path) {
            guard !FileManager.default.fileExists(atPath: move.source.path) else {
                throw DesktopRecoveryError.destinationExists
            }
            try FileManager.default.createDirectory(
                at: move.source.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try runtimeMoveItem(move.archive, move.source)
        }
        guard moves.allSatisfy({
            FileManager.default.fileExists(atPath: $0.source.path)
                && !FileManager.default.fileExists(atPath: $0.archive.path)
        }) else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
    }

    public func hasRuntimeState() throws -> Bool {
        try !regularFiles(below: localCoreDirectoryURL).isEmpty
            || !regularFiles(below: conversationServiceDirectoryURL).isEmpty
            || !regularFiles(below: workflowInstallationsDirectoryURL).isEmpty
            || !regularFiles(below: workflowCapabilitiesDirectoryURL).isEmpty
            || !regularFiles(below: workflowLibraryDirectoryURL).isEmpty
            || !regularFiles(below: workflowObjectsDirectoryURL).isEmpty
    }

    public func activateVerifiedRuntimeRestore(
        from bundleURL: URL,
        restoreID: UUID
    ) throws -> DesktopRuntimeRestoreTransaction {
        let service = DesktopRecoveryService()
        let manifest = try service.validateBackup(at: bundleURL)
        let runtimeKinds: Set<DesktopRecoveryArtifactKind> = [
            .localCoreJournal,
            .localCoreSnapshot,
            .conversationServiceState,
            .workflowInstallationState,
            .workflowCapabilityPackage,
            .workflowLibraryState,
            .workflowObjectState,
        ]
        let runtimeArtifacts = try service.verifiedArtifacts(kinds: runtimeKinds, from: bundleURL)
        guard manifest.runtimeStateIncluded == true else {
            guard runtimeArtifacts.isEmpty else { throw DesktopModelRecoveryError.restoreArtifactInvalid }
            if try hasRuntimeState() { throw DesktopModelRecoveryError.restoreArtifactInvalid }
            return DesktopRuntimeRestoreTransaction(
                originalMoves: [],
                activatedRoots: [],
                failedRestoreDirectory: managedRecoveryDirectoryURL
            )
        }
        let stagingRoot = managedRecoveryDirectoryURL
            .appendingPathComponent("RuntimeRestoreStaging", isDirectory: true)
            .appendingPathComponent(restoreID.uuidString.lowercased(), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: stagingRoot.path) else {
            throw DesktopRecoveryError.destinationExists
        }
        try preparePrivateDirectory(stagingRoot)
        do {
            for artifact in runtimeArtifacts {
                guard let relativePath = artifact.manifest.restoreRelativePath,
                      Self.runtimeRestorePathIsAllowed(relativePath, kind: artifact.manifest.kind) else {
                    throw DesktopModelRecoveryError.restoreArtifactInvalid
                }
                let destination = stagingRoot.appendingPathComponent(relativePath)
                try preparePrivateDirectory(destination.deletingLastPathComponent())
                try writePrivate(artifact.data, to: destination)
            }
            let originalMoves = try archiveRuntimeState(resetID: restoreID)
            var activatedRoots: [URL] = []
            let failedRestoreDirectory = managedRecoveryDirectoryURL
                .appendingPathComponent("FailedRuntimeRestores", isDirectory: true)
                .appendingPathComponent(restoreID.uuidString.lowercased(), isDirectory: true)
            do {
                for name in [
                    "LocalCore", "ConversationService", "WorkflowInstallations",
                    "WorkflowCapabilities", "Workflows", "Objects",
                ] {
                    let staged = stagingRoot.appendingPathComponent(name, isDirectory: true)
                    guard FileManager.default.fileExists(atPath: staged.path) else { continue }
                    let active = applicationSupportRootURL.appendingPathComponent(name, isDirectory: true)
                    guard !FileManager.default.fileExists(atPath: active.path) else {
                        throw DesktopRecoveryError.destinationExists
                    }
                    try runtimeMoveItem(staged, active)
                    activatedRoots.append(active)
                }
                return DesktopRuntimeRestoreTransaction(
                    originalMoves: originalMoves,
                    activatedRoots: activatedRoots,
                    failedRestoreDirectory: failedRestoreDirectory
                )
            } catch {
                let transaction = DesktopRuntimeRestoreTransaction(
                    originalMoves: originalMoves,
                    activatedRoots: activatedRoots,
                    failedRestoreDirectory: failedRestoreDirectory
                )
                do {
                    try rollbackRuntimeRestore(transaction)
                } catch {
                    try? persistRecoveryFailureEvent(DesktopRedactedDiagnosticEvent(
                        category: "recovery",
                        code: "runtime-activation-rollback-unverified",
                        occurredAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
                    ))
                    throw DesktopModelRecoveryError.recoveryRollbackFailed
                }
                throw error
            }
        } catch {
            throw error
        }
    }

    public func rollbackRuntimeRestore(_ transaction: DesktopRuntimeRestoreTransaction) throws {
        if !transaction.activatedRoots.isEmpty {
            try preparePrivateDirectory(transaction.failedRestoreDirectory)
        }
        for active in transaction.activatedRoots.reversed()
        where FileManager.default.fileExists(atPath: active.path) {
            let failed = transaction.failedRestoreDirectory.appendingPathComponent(active.lastPathComponent, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: failed.path) else {
                throw DesktopRecoveryError.destinationExists
            }
            try runtimeMoveItem(active, failed)
        }
        try restoreArchivedRuntimeState(transaction.originalMoves)
        guard transaction.activatedRoots.allSatisfy({ active in
            FileManager.default.fileExists(
                atPath: transaction.failedRestoreDirectory.appendingPathComponent(active.lastPathComponent).path
            )
        }) else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
    }

    private static func runtimeRestorePathIsAllowed(
        _ path: String,
        kind: DesktopRecoveryArtifactKind
    ) -> Bool {
        switch kind {
        case .localCoreJournal, .localCoreSnapshot:
            path.hasPrefix("LocalCore/")
        case .conversationServiceState:
            path.hasPrefix("ConversationService/")
        case .workflowInstallationState:
            path.hasPrefix("WorkflowInstallations/")
        case .workflowCapabilityPackage:
            path.hasPrefix("WorkflowCapabilities/")
        case .workflowLibraryState:
            path.hasPrefix("Workflows/")
        case .workflowObjectState:
            path.hasPrefix("Objects/")
        case .workspaceState, .previousWorkspaceState:
            false
        }
    }

    private func recoverySources(includesRuntimeState: Bool) throws -> [DesktopRecoverySource] {
        var sources: [DesktopRecoverySource] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard try DesktopRecoveryService.isRegularNonSymlink(fileURL) else { throw DesktopRecoveryError.unsafeSource }
            sources.append(.init(kind: .workspaceState, fileURL: fileURL, archiveName: "workspace.json"))
        }
        if FileManager.default.fileExists(atPath: recoveryFileURL.path) {
            guard try DesktopRecoveryService.isRegularNonSymlink(recoveryFileURL) else { throw DesktopRecoveryError.unsafeSource }
            sources.append(.init(kind: .previousWorkspaceState, fileURL: recoveryFileURL, archiveName: "workspace.previous.json"))
        }
        guard includesRuntimeState else { return sources }
        sources += try runtimeRecoverySources(
            below: localCoreDirectoryURL,
            kind: .localCoreJournal,
            restorePrefix: "LocalCore",
            archivePrefix: "local-core"
        )
        sources += try runtimeRecoverySources(
            below: conversationServiceDirectoryURL,
            kind: .conversationServiceState,
            restorePrefix: "ConversationService",
            archivePrefix: "conversation"
        )
        sources += try runtimeRecoverySources(
            below: workflowInstallationsDirectoryURL,
            kind: .workflowInstallationState,
            restorePrefix: "WorkflowInstallations",
            archivePrefix: "workflow-installation"
        )
        sources += try runtimeRecoverySources(
            below: workflowCapabilitiesDirectoryURL,
            kind: .workflowCapabilityPackage,
            restorePrefix: "WorkflowCapabilities",
            archivePrefix: "workflow-capability"
        )
        sources += try runtimeRecoverySources(
            below: workflowLibraryDirectoryURL,
            kind: .workflowLibraryState,
            restorePrefix: "Workflows",
            archivePrefix: "workflow-library"
        )
        sources += try runtimeRecoverySources(
            below: workflowObjectsDirectoryURL,
            kind: .workflowObjectState,
            restorePrefix: "Objects",
            archivePrefix: "workflow-object"
        )
        guard sources.count <= 4_098 else { throw DesktopRecoveryError.unsafeSource }
        return sources
    }

    private func runtimeRecoverySources(
        below root: URL,
        kind: DesktopRecoveryArtifactKind,
        restorePrefix: String,
        archivePrefix: String
    ) throws -> [DesktopRecoverySource] {
        try regularFiles(below: root).map { url in
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            let restorePath = "\(restorePrefix)/\(relative)"
            let opaqueName = "\(archivePrefix)-\(DesktopRecoveryService.sha256(Data(restorePath.utf8)).prefix(32)).bin"
            return DesktopRecoverySource(
                kind: kind,
                fileURL: url,
                archiveName: opaqueName,
                restoreRelativePath: restorePath
            )
        }
    }

    private func regularFiles(below root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw DesktopRecoveryError.unsafeSource
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw DesktopRecoveryError.missingSource }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw DesktopRecoveryError.unsafeSource }
            guard values.isRegularFile == true else { continue }
            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalPath.hasPrefix(canonicalRoot + "/") else { throw DesktopRecoveryError.unsafeSource }
            files.append(url)
            guard files.count <= 4_096 else { throw DesktopRecoveryError.unsafeSource }
        }
        return files.sorted { $0.path < $1.path }
    }

    public func persistMigrationReceipt(_ receipt: DesktopMigrationReceipt) throws {
        try persistRecoveryDocument(receipt, name: "migration-\(receipt.migrationID.uuidString.lowercased()).json")
    }

    public func persistRestoreReceipt(_ receipt: DesktopRestoreReceipt) throws {
        try persistRecoveryDocument(receipt, name: "restore-\(receipt.restoreID.uuidString.lowercased()).json")
    }

    public func persistResetManifest(_ manifest: DesktopResetManifest) throws {
        try persistRecoveryDocument(manifest, name: "reset-\(manifest.resetID.uuidString.lowercased()).json")
    }

    public func persistRecoveryFailureEvent(_ event: DesktopRedactedDiagnosticEvent) throws {
        try persistRecoveryDocument(event, name: "failure-\(UUID().uuidString.lowercased()).json")
    }

    public func persistRecoveryLockMarker(_ event: DesktopRedactedDiagnosticEvent) throws {
        guard event.category == "recovery",
              event.occurredAtUnixMillis >= 0,
              event.privateDetailByteCount == 0,
              event.privateDetailSHA256 == nil else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
        try preparePrivateDirectory(managedRecoveryDirectoryURL)
        let data = try recoveryEncoder.encode(event)
        try writePrivate(data, to: recoveryLockMarkerURL)
        guard try readPrivateIfPresent(at: recoveryLockMarkerURL) == data else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
    }

    public func loadRecoveryLockMarker() throws -> DesktopRedactedDiagnosticEvent? {
        guard let data = try readPrivateIfPresent(at: recoveryLockMarkerURL) else { return nil }
        let event = try JSONDecoder().decode(DesktopRedactedDiagnosticEvent.self, from: data)
        guard event.category == "recovery",
              event.occurredAtUnixMillis >= 0,
              event.privateDetailByteCount == 0,
              event.privateDetailSHA256 == nil else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
        return DesktopRedactedDiagnosticEvent(
            category: event.category,
            code: event.code,
            occurredAtUnixMillis: event.occurredAtUnixMillis
        )
    }

    public func clearRecoveryLockMarker() throws {
        guard FileManager.default.fileExists(atPath: recoveryLockMarkerURL.path) else { return }
        guard try DesktopRecoveryService.isRegularNonSymlink(recoveryLockMarkerURL) else {
            throw DesktopRecoveryError.unsafeSource
        }
        try FileManager.default.removeItem(at: recoveryLockMarkerURL)
        guard !FileManager.default.fileExists(atPath: recoveryLockMarkerURL.path) else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
    }

    private func persistRecoveryDocument<Value: Encodable>(_ value: Value, name: String) throws {
        try preparePrivateDirectory(receiptDirectoryURL)
        try writePrivate(try recoveryEncoder.encode(value), to: receiptDirectoryURL.appendingPathComponent(name))
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try preparePrivateDirectory(directory)
    }

    private func preparePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try DesktopRecoveryService.isRegularNonSymlink(url) else { throw DesktopRecoveryError.unsafeSource }
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func readPrivateIfPresent(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try DesktopRecoveryService.isRegularNonSymlink(url) else { throw DesktopRecoveryError.unsafeSource }
        return try Data(contentsOf: url)
    }

    private var recoveryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

@MainActor
public final class DesktopAppModel: ObservableObject {
    @Published public private(set) var snapshot: DesktopAppSnapshot
    @Published public private(set) var persistenceError: String?
    @Published public private(set) var recoveryStatus: DesktopRecoveryStatus?

    private let store: any DesktopStateStoring
    let now: () -> Int64
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var providerEventIDs: Set<String>
    // SwiftUI owns the visible draft. This non-published cache keeps keystrokes
    // off the monolithic workspace encoder until an idle or explicit checkpoint.
    private var composerDraftCache: [String: String] = [:]
    private var composerDraftSaveTask: _Concurrency.Task<Void, Never>?
    private var composerDraftGeneration: UInt64 = 0
    private var persistedComposerDraftGeneration: UInt64 = 0
    private let composerDraftSaveDelay: Duration

    public init(
        store: any DesktopStateStoring = FileDesktopStateStore.applicationSupport(),
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        composerDraftSaveDelay: Duration = .milliseconds(300)
    ) {
        self.store = store
        self.now = now
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.providerEventIDs = []
        self.composerDraftSaveDelay = composerDraftSaveDelay
        self.recoveryStatus = nil
        let timestamp = now()
        let runtimeRecoveryLockDetected: Bool
        if let fileStore = store as? FileDesktopStateStore {
            do {
                runtimeRecoveryLockDetected = try fileStore.loadRecoveryLockMarker() != nil
            } catch {
                runtimeRecoveryLockDetected = true
            }
        } else {
            runtimeRecoveryLockDetected = false
        }
        if runtimeRecoveryLockDetected {
            do {
                if let data = try store.load(),
                   let restored = try? Self.currentSnapshot(from: data, decoder: decoder, now: timestamp) {
                    self.snapshot = restored.snapshot
                } else {
                    self.snapshot = DesktopAppSnapshot.starter(now: timestamp)
                }
            } catch {
                self.snapshot = DesktopAppSnapshot.starter(now: timestamp)
            }
            let previousWorkspaceAvailable: Bool
            if let recoveryStore = store as? any DesktopRecoveryStateStoring {
                previousWorkspaceAvailable = ((try? recoveryStore.loadRecovery()) ?? nil) != nil
            } else {
                previousWorkspaceAvailable = false
            }
            self.recoveryStatus = DesktopRecoveryStatus(
                reason: .runtimeRollbackUnverified,
                detectedStateSchemaVersion: snapshot.version,
                quarantineCreated: false,
                previousWorkspaceAvailable: previousWorkspaceAvailable
            )
            self.persistenceError = DesktopModelRecoveryError.recoveryRollbackFailed.localizedDescription
        } else {
            do {
            if let data = try store.load() {
                let declaredVersion = Self.declaredSchemaVersion(from: data)
                var backupID: UUID?
                let migrationID = UUID()
                if let declaredVersion, declaredVersion < DesktopAppSnapshot.currentVersion,
                   let fileStore = store as? FileDesktopStateStore {
                    backupID = try fileStore.createPrivateBackupHistory(
                        stateSchemaVersion: declaredVersion,
                        createdAtUnixMillis: timestamp
                    )?.backupID
                }
                let restored = try Self.currentSnapshot(from: data, decoder: decoder, now: timestamp)
                if restored.didMigrate {
                    do {
                        let migratedData = try encoder.encode(restored.snapshot)
                        try store.save(migratedData)
                        guard try store.load() == migratedData else {
                            throw DesktopModelRecoveryError.persistenceVerificationFailed
                        }
                        try (store as? FileDesktopStateStore)?.persistMigrationReceipt(DesktopMigrationReceipt(
                            migrationID: migrationID,
                            fromStateSchemaVersion: declaredVersion ?? restored.snapshot.version,
                            toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
                            startedAtUnixMillis: timestamp,
                            completedAtUnixMillis: now(),
                            outcome: .applied,
                            backupID: backupID
                        ))
                    } catch {
                        try? (store as? FileDesktopStateStore)?.persistMigrationReceipt(DesktopMigrationReceipt(
                            migrationID: migrationID,
                            fromStateSchemaVersion: declaredVersion ?? 0,
                            toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
                            startedAtUnixMillis: timestamp,
                            completedAtUnixMillis: now(),
                            outcome: .failed,
                            backupID: backupID,
                            reasonCode: "migration-persistence-failed"
                        ))
                        throw error
                    }
                }
                self.snapshot = restored.snapshot
            } else {
                let starter = DesktopAppSnapshot.starter(now: timestamp)
                self.snapshot = starter
                try store.save(try encoder.encode(starter))
            }
            } catch {
            let primaryData: Data?
            let primaryReadFailed: Bool
            do {
                primaryData = try store.load()
                primaryReadFailed = false
            } catch {
                primaryData = nil
                primaryReadFailed = true
            }
            let declaredVersion = primaryData.flatMap(Self.declaredSchemaVersion(from:))
            let reason: DesktopRecoveryReason
            if let declaredVersion, declaredVersion > DesktopAppSnapshot.currentVersion {
                reason = .unsupportedStateVersion
            } else if declaredVersion != nil {
                reason = .migrationFailed
            } else if primaryReadFailed {
                reason = .unreadableState
            } else if primaryData == nil {
                reason = .initialPersistenceFailed
            } else {
                reason = .unreadableState
            }
            let quarantineCreated = ((try? (store as? FileDesktopStateStore)?.quarantinePrimary(
                reasonCode: reason.rawValue,
                detectedAtUnixMillis: timestamp
            )) ?? nil) != nil
            var previousWorkspaceAvailable = false
            if let recoveryStore = store as? any DesktopRecoveryStateStoring,
               let recoveryData = try? recoveryStore.loadRecovery(),
               let recovered = try? Self.currentSnapshot(from: recoveryData, decoder: decoder, now: timestamp) {
                self.snapshot = recovered.snapshot
                previousWorkspaceAvailable = true
            } else {
                self.snapshot = DesktopAppSnapshot.starter(now: timestamp)
            }
            self.recoveryStatus = DesktopRecoveryStatus(
                reason: reason,
                detectedStateSchemaVersion: declaredVersion,
                quarantineCreated: quarantineCreated,
                previousWorkspaceAvailable: previousWorkspaceAvailable
            )
            // Recovery is a first-class blocking workspace, not a transient
            // save error. Keeping the generic alert clear lets Recovery Center
            // present the preserved-state choices without an alert obscuring it.
                self.persistenceError = nil
            }
        }
        providerEventIDs = Set(snapshot.operations.providerEvents.map(\.id))
        composerDraftCache = snapshot.operations.composerDrafts
        persistedComposerDraftGeneration = composerDraftGeneration
    }

    public var isRecoveryReadOnly: Bool { recoveryStatus != nil }

    public var requiresArchiveConfirmation: Bool {
        snapshot.preferences.confirmBeforeArchiving
    }

    public var activeThreads: [DesktopThread] {
        snapshot.threads
            .filter { $0.attention != .archived }
            .sorted {
                $0.createdAtUnixMillis == $1.createdAtUnixMillis
                    ? $0.id < $1.id
                    : $0.createdAtUnixMillis > $1.createdAtUnixMillis
            }
    }

    public var archivedThreads: [DesktopThread] {
        snapshot.threads
            .filter { $0.attention == .archived }
            .sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }
    }

    public var activeProjects: [DesktopProject] {
        snapshot.projects
            .filter { $0.archivedAtUnixMillis == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var archivedProjects: [DesktopProject] {
        snapshot.projects
            .filter { $0.archivedAtUnixMillis != nil }
            .sorted { ($0.archivedAtUnixMillis ?? 0) > ($1.archivedAtUnixMillis ?? 0) }
    }

    public func thread(id: String?) -> DesktopThread? {
        guard let id else { return nil }
        return snapshot.threads.first { $0.id == id }
    }

    public func project(id: String?) -> DesktopProject? {
        guard let id else { return nil }
        return snapshot.projects.first { $0.id == id }
    }

    public func projects(matching query: String, includeArchived: Bool = false) -> [DesktopProject] {
        let normalized = Self.normalized(query).lowercased()
        let projects = includeArchived ? archivedProjects : activeProjects
        guard !normalized.isEmpty else { return projects }
        return projects.filter { project in
            project.name.lowercased().contains(normalized)
                || project.summary.lowercased().contains(normalized)
                || project.path?.lowercased().contains(normalized) == true
                || project.context.instructionReferences.contains { $0.lowercased().contains(normalized) }
        }
    }

    public func threads(matching query: String, attention: DesktopAttention? = nil) -> [DesktopThread] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return activeThreads.filter { thread in
            let matchesAttention = attention == nil || thread.attention == attention
            let matchesQuery = normalized.isEmpty
                || thread.title.lowercased().contains(normalized)
                || thread.summary.lowercased().contains(normalized)
                || thread.messages.contains { $0.body.lowercased().contains(normalized) }
            return matchesAttention && matchesQuery
        }
    }

    @discardableResult
    public func createThread(
        title: String,
        kind: DesktopWorkKind,
        projectID: String?
    ) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= 160 else { return nil }
        let timestamp = now()
        let thread = DesktopThread(
            projectID: projectID,
            title: cleanTitle,
            summary: "Local conversation ready. No provider or external service has been started.",
            kind: kind,
            attention: .queued,
            updatedAtUnixMillis: timestamp,
            messages: [
                DesktopMessage(
                    role: .system,
                    body: "Created locally in Kaname. Choose a validated execution surface before granting provider or write authority.",
                    createdAtUnixMillis: timestamp
                ),
            ]
        )
        mutate { $0.threads.append(thread) }
        return thread.id
    }

    public func createConversation(
        kind: DesktopWorkKind,
        projectID: String?,
        provider: String? = nil,
        model: String? = nil,
        reasoningEffort: String = "medium",
        runtimeMode: ConversationRuntimeMode = .approvalRequired,
        networkAccess: Bool = false
    ) -> String {
        let timestamp = now()
        let selectedProvider = provider ?? project(id: projectID)?.context.defaultProvider ?? "Codex"
        let selectedModel = model ?? project(id: projectID)?.context.defaultModel ?? "Use provider default"
        let thread = DesktopThread(
            projectID: projectID,
            title: kind.newConversationTitle,
            summary: "Ready for your first message.",
            kind: kind,
            attention: .queued,
            provider: selectedProvider,
            model: selectedModel,
            reasoningEffort: reasoningEffort,
            runtimeMode: runtimeMode,
            networkAccess: runtimeMode == .fullAccess ? true : networkAccess,
            titleSource: .placeholder,
            updatedAtUnixMillis: timestamp
        )
        mutate { $0.threads.append(thread) }
        return thread.id
    }

    public func createOrReuseConversationDraft(
        kind: DesktopWorkKind,
        projectID: String?,
        provider: String? = nil,
        model: String? = nil,
        reasoningEffort: String = "medium",
        runtimeMode: ConversationRuntimeMode = .approvalRequired,
        networkAccess: Bool = false
    ) -> String {
        let selectedProvider = provider ?? project(id: projectID)?.context.defaultProvider ?? "Codex"
        let selectedModel = model ?? project(id: projectID)?.context.defaultModel ?? "Use provider default"
        if let existing = snapshot.threads.last(where: { thread in
            thread.projectID == projectID
                && thread.kind == kind
                && thread.titleSource == .placeholder
                && thread.messages.isEmpty
                && !snapshot.operations.providerRuns.contains { $0.threadID == thread.id }
        }) {
            mutate { snapshot in
                guard let index = snapshot.threads.firstIndex(where: { $0.id == existing.id }) else { return }
                snapshot.threads[index].provider = selectedProvider
                snapshot.threads[index].model = selectedModel
                snapshot.threads[index].reasoningEffort = reasoningEffort
                snapshot.threads[index].runtimeMode = runtimeMode
                snapshot.threads[index].networkAccess = runtimeMode == .fullAccess ? true : networkAccess
                snapshot.threads[index].updatedAtUnixMillis = now()
            }
            return existing.id
        }
        return createConversation(
            kind: kind,
            projectID: projectID,
            provider: selectedProvider,
            model: selectedModel,
            reasoningEffort: reasoningEffort,
            runtimeMode: runtimeMode,
            networkAccess: networkAccess
        )
    }

    /// Compacts a thread: keeps every message on disk, but marks a cut so that
    /// providers start a fresh native session seeded with a bounded digest of the
    /// conversation so far. Provider-neutral and instant (no LLM call).
    @discardableResult
    public func compactThread(threadID: String) -> Bool {
        guard let thread = thread(id: threadID), thread.messages.count >= 2,
              let lastMessage = thread.messages.last else { return false }
        let digest = Self.compactionDigest(thread: thread)
        let compaction = DesktopThreadCompaction(
            summary: digest,
            throughMessageID: lastMessage.id,
            messageCount: thread.messages.count,
            createdAtUnixMillis: now()
        )
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].compaction = compaction
            snapshot.threads[index].updatedAtUnixMillis = compaction.createdAtUnixMillis
        }
        return persistenceError == nil
    }

    /// Replaces the compaction digest with a better summary (for example one a
    /// model wrote) as long as the compaction it was written for is still the
    /// current one. Returns false when the thread was compacted again since.
    @discardableResult
    public func updateCompactionSummary(threadID: String, throughMessageID: String, summary: String) -> Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let thread = thread(id: threadID),
              let compaction = thread.compaction,
              compaction.throughMessageID == throughMessageID else { return false }
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  snapshot.threads[index].compaction?.throughMessageID == throughMessageID else { return }
            snapshot.threads[index].compaction?.summary = KanameTextBounds.utf8Prefix(trimmed, maximumBytes: 12_000)
        }
        return persistenceError == nil
    }

    static func compactionDigest(thread: DesktopThread) -> String {
        func clip(_ text: String, _ bytes: Int) -> String {
            let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return KanameTextBounds.utf8Prefix(flat, maximumBytes: bytes) + (flat.utf8.count > bytes ? "…" : "")
        }
        var parts: [String] = []
        if let first = thread.messages.first(where: { $0.role == .user }) {
            parts.append("Original request:\n" + clip(first.body, 1_200))
        }
        if let plan = thread.planBody, !plan.isEmpty {
            parts.append("Current plan:\n" + clip(plan, 2_400))
        } else if !thread.plan.isEmpty {
            parts.append("Current plan:\n" + thread.plan.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n"))
        }
        if let findings = thread.findings, !findings.isEmpty {
            parts.append("Findings so far:\n" + findings.suffix(12).map { "- " + clip($0.detail, 240) }.joined(separator: "\n"))
        }
        let recent = thread.messages.suffix(8).filter { $0.role != .system }
        if !recent.isEmpty {
            parts.append("Most recent exchange:\n" + recent.map { "\($0.role == .user ? "User" : "Assistant"): " + clip($0.body, 600) }.joined(separator: "\n\n"))
        }
        if let previous = thread.compaction?.summary, !previous.isEmpty {
            parts.append("Earlier compaction digest:\n" + clip(previous, 1_500))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Appends a Kaname-authored note to a thread (for example a pull request link).
    @discardableResult
    public func appendSystemMessage(threadID: String, body: String) -> String? {
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBody.isEmpty, cleanBody.utf8.count <= 32_000 else { return nil }
        let message = DesktopMessage(role: .system, body: cleanBody, createdAtUnixMillis: now())
        var appended = false
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].messages.append(message)
            appended = true
        }
        return appended ? message.id : nil
    }

    public func appendUserMessage(
        threadID: String,
        body: String,
        attachments: [ConversationImageAttachment] = []
    ) -> String? {
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!cleanBody.isEmpty || !attachments.isEmpty),
              cleanBody.utf8.count <= 32_000,
              attachments.count <= ConversationImageAttachment.maximumCountPerMessage else { return nil }
        let timestamp = now()
        let message = DesktopMessage(
            role: .user,
            body: cleanBody,
            attachments: attachments,
            createdAtUnixMillis: timestamp
        )
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            let shouldProjectTitle = snapshot.threads[index].title == snapshot.threads[index].kind.newConversationTitle
                && !snapshot.threads[index].messages.contains { $0.role == .user }
            snapshot.threads[index].messages.append(message)
            if shouldProjectTitle {
                snapshot.threads[index].title = Self.provisionalConversationTitle(
                    from: cleanBody.isEmpty ? attachments.first?.filename ?? "Image conversation" : cleanBody
                )
                snapshot.threads[index].titleSource = .provisional
            }
            snapshot.threads[index].summary = cleanBody.isEmpty
                ? "\(attachments.count) image\(attachments.count == 1 ? "" : "s") attached"
                : cleanBody
            snapshot.threads[index].attention = .queued
            snapshot.threads[index].updatedAtUnixMillis = timestamp
            snapshot.threads[index].unread = false
        }
        return snapshot.threads.contains(where: { $0.id == threadID && $0.messages.contains(where: { $0.id == message.id }) })
            ? message.id
            : nil
    }

    public func renameThread(id: String, title: String) -> Bool {
        let cleanTitle = Self.normalized(title)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= 160 else { return false }
        return mutateThread(id: id) { thread in
            thread.title = cleanTitle
            thread.titleSource = .manual
            thread.updatedAtUnixMillis = now()
        }
    }

    public func updateThreadRuntime(
        id: String,
        provider: String,
        model: String,
        reasoningEffort: String,
        runtimeMode: ConversationRuntimeMode,
        networkAccess: Bool
    ) -> Bool {
        let cleanProvider = Self.normalized(provider)
        let cleanModel = Self.normalized(model)
        let cleanReasoning = Self.normalized(reasoningEffort).lowercased()
        guard !cleanProvider.isEmpty, cleanProvider.utf8.count <= 120,
              !cleanModel.isEmpty, cleanModel.utf8.count <= 200,
              Self.isBoundedProviderIdentifier(cleanReasoning),
              !snapshot.operations.providerRuns.contains(where: { $0.threadID == id && $0.state == .running }) else {
            return false
        }
        return mutateThread(id: id) { thread in
            thread.provider = cleanProvider
            thread.model = cleanModel
            thread.reasoningEffort = cleanReasoning
            thread.runtimeMode = runtimeMode
            thread.networkAccess = runtimeMode == .fullAccess ? true : networkAccess
            thread.updatedAtUnixMillis = now()
        }
    }

    public func applyProviderGeneratedTitle(threadID: String, title: String) -> Bool {
        guard let cleanTitle = DesktopConversationTitleGeneration.normalizedTitle(from: title) else { return false }
        guard thread(id: threadID)?.titleSource == .provisional else { return false }
        return mutateThread(id: threadID) { thread in
            thread.title = cleanTitle
            thread.titleSource = .providerGenerated
            thread.updatedAtUnixMillis = now()
        }
    }

    public func applyProviderRegeneratedTitle(
        threadID: String,
        title: String,
        expectedTitle: String,
        expectedSource: DesktopConversationTitleSource
    ) -> Bool {
        guard let cleanTitle = DesktopConversationTitleGeneration.normalizedTitle(from: title),
              let current = thread(id: threadID),
              cleanTitle != expectedTitle,
              current.title == expectedTitle,
              current.titleSource == expectedSource else { return false }
        return mutateThread(id: threadID) { thread in
            thread.title = cleanTitle
            thread.titleSource = .providerGenerated
            thread.updatedAtUnixMillis = now()
        }
    }

    public func markProviderTitleFallback(threadID: String) {
        guard thread(id: threadID)?.titleSource == .provisional else { return }
        mutateThread(id: threadID) { thread in
            thread.titleSource = .providerFallback
        }
    }

    public func providerEvents(threadID: String) -> [DesktopProviderEventRecord] {
        snapshot.operations.providerEvents
            .filter { $0.threadID == threadID }
            .sorted { $0.createdAtUnixMillis < $1.createdAtUnixMillis }
    }

    public func providerRuns(threadID: String) -> [DesktopProviderRunRecord] {
        snapshot.operations.providerRuns
            .filter { $0.threadID == threadID }
            .sorted { $0.startedAtUnixMillis < $1.startedAtUnixMillis }
    }

    public func providerRun(id: String) -> DesktopProviderRunRecord? {
        snapshot.operations.providerRuns.first { $0.id == id }
    }

    public var providerActivityThreadIDsRequiringPolling: Set<String> {
        let providerRunThreadIDs: [String] = snapshot.operations.providerRuns.compactMap { run -> String? in
            guard run.state == .proposed || run.state == .running else { return nil }
            return run.threadID
        }
        let activeSubagentThreadIDs: [String] = snapshot.operations.subagents.compactMap { subagent -> String? in
            guard Self.isActiveSubagentState(subagent.state) else { return nil }
            return subagent.threadID
        }
        return Set(providerRunThreadIDs).union(activeSubagentThreadIDs)
    }

    public func hasActiveSubagents(threadID: String) -> Bool {
        snapshot.operations.subagents.contains {
            $0.threadID == threadID && Self.isActiveSubagentState($0.state)
        }
    }

    @discardableResult
    public func recoverOrphanedSubagents(threadID: String) -> Bool {
        guard hasActiveSubagents(threadID: threadID) else { return true }
        let timestamp = now()
        return mutate { snapshot in
            Self.interruptActiveSubagents(in: &snapshot, threadID: threadID, timestamp: timestamp)
        }
    }

    public func composerDraft(threadID: String) -> String {
        composerDraftCache[threadID] ?? ""
    }

    public func composerAttachments(threadID: String) -> [ConversationImageAttachment] {
        snapshot.operations.composerAttachmentDrafts[threadID] ?? []
    }

    @discardableResult
    public func updateComposerDraft(threadID: String, body: String) -> Bool {
        guard snapshot.threads.contains(where: { $0.id == threadID }), body.utf8.count <= 32_000 else { return false }
        guard recoveryStatus == nil else {
            persistenceError = "Kaname is keeping this recovery workspace read-only until verified state is restored or exported."
            return false
        }
        guard composerDraftCache[threadID] != body else { return persistenceError == nil }
        if body.isEmpty {
            composerDraftCache.removeValue(forKey: threadID)
        } else {
            composerDraftCache[threadID] = body
        }
        composerDraftGeneration &+= 1
        scheduleComposerDraftPersistence()
        return persistenceError == nil
    }

    @discardableResult
    public func flushComposerDrafts() -> Bool {
        guard composerDraftGeneration != persistedComposerDraftGeneration else {
            return true
        }
        composerDraftSaveTask?.cancel()
        composerDraftSaveTask = nil
        return mutate { _ in }
    }

    @discardableResult
    public func addComposerAttachment(
        threadID: String,
        attachment: ConversationImageAttachment
    ) -> Bool {
        guard snapshot.threads.contains(where: { $0.id == threadID }) else { return false }
        let current = composerAttachments(threadID: threadID)
        guard current.count < ConversationImageAttachment.maximumCountPerMessage,
              !current.contains(where: { $0.id == attachment.id }) else { return false }
        mutate { $0.operations.composerAttachmentDrafts[threadID, default: []].append(attachment) }
        return persistenceError == nil
    }

    @discardableResult
    public func removeComposerAttachment(
        threadID: String,
        attachmentID: String
    ) -> ConversationImageAttachment? {
        var removed: ConversationImageAttachment?
        mutate { snapshot in
            guard var attachments = snapshot.operations.composerAttachmentDrafts[threadID],
                  let index = attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
            removed = attachments.remove(at: index)
            if attachments.isEmpty {
                snapshot.operations.composerAttachmentDrafts.removeValue(forKey: threadID)
            } else {
                snapshot.operations.composerAttachmentDrafts[threadID] = attachments
            }
        }
        return removed
    }

    public func clearComposerDraft(threadID: String) {
        if composerDraftCache.removeValue(forKey: threadID) != nil {
            composerDraftGeneration &+= 1
        }
        composerDraftSaveTask?.cancel()
        composerDraftSaveTask = nil
        mutate { snapshot in
            snapshot.operations.composerDrafts.removeValue(forKey: threadID)
            snapshot.operations.composerAttachmentDrafts.removeValue(forKey: threadID)
        }
    }

    public func message(threadID: String, id: String) -> DesktopMessage? {
        thread(id: threadID)?.messages.first { $0.id == id }
    }

    public func workspaceURL(threadID: String) -> URL? {
        guard let thread = thread(id: threadID), let projectID = thread.projectID else { return nil }
        if let path = project(id: projectID)?.path, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        guard let path = snapshot.domains.gitWorkspaces.first(where: {
            $0.projectID == projectID && $0.status == .ready
        })?.localPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    @discardableResult
    public func enqueueProviderRun(
        threadID: String,
        sourceMessageID: String,
        usesProjectContext: Bool = true,
        workspacePathOverride: String? = nil,
        purpose: DesktopProviderRunPurpose = .conversation,
        runtimeModeOverride: ConversationRuntimeMode? = nil,
        networkAccessOverride: Bool? = nil
    ) -> String? {
        guard let thread = thread(id: threadID),
              let message = thread.messages.first(where: { $0.id == sourceMessageID && $0.role == .user }) else {
            return nil
        }
        if purpose == .codingPlan,
           let state = codingWorkflow(threadID: threadID)?.state,
           ![.discussing, .awaitingPlanApproval, .completed, .rejected, .failed].contains(state) {
            return nil
        }
        let run = DesktopProviderRunRecord(
            id: UUID().uuidString.lowercased(),
            threadID: threadID,
            sourceMessageID: sourceMessageID,
            turnID: message.turnID ?? message.id,
            provider: thread.provider,
            model: thread.model,
            reasoningEffort: thread.reasoningEffort,
            runtimeMode: runtimeModeOverride ?? thread.runtimeMode,
            networkAccess: networkAccessOverride ?? thread.networkAccess,
            briefDigest: Self.stableLocalDigest(message.body),
            contextReferenceCount: providerContextReferenceCount(for: thread),
            tokenUsage: nil,
            costSummary: "Pending",
            state: .proposed,
            startedAtUnixMillis: now(),
            completedAtUnixMillis: nil,
            usesProjectContext: usesProjectContext,
            workspacePathOverride: workspacePathOverride,
            purpose: purpose
        )
        let persisted = mutate { snapshot in
            snapshot.operations.providerRuns.append(run)
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            if purpose == .codingPlan {
                if let laneIndex = snapshot.operations.codingKnowledgeLanes.firstIndex(where: {
                    $0.threadID == threadID
                }) {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].consultedSources.removeAll()
                    snapshot.operations.codingKnowledgeLanes[laneIndex].candidates.removeAll()
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .collecting
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "A new coding cycle is collecting exact context and durable candidates."
                    snapshot.operations.codingKnowledgeLanes[laneIndex].acceptedWorktreeID = nil
                    snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID = nil
                    snapshot.operations.codingKnowledgeLanes[laneIndex].writeID = nil
                    snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = now()
                }
                // A planning turn refines the existing plan; only a fresh cycle
                // after completion, rejection, or failure starts from nothing.
                let previousState = snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state
                if [.completed, .rejected, .failed].contains(previousState ?? .discussing) {
                    snapshot.threads[index].plan.removeAll()
                    snapshot.threads[index].planBody = nil
                }
                snapshot.threads[index].evidence.removeAll()
                snapshot.threads[index].summary = "Planning…"
                Self.setCodingWorkflow(
                    in: &snapshot,
                    threadID: threadID,
                    state: .planning,
                    reason: "Read-only implementation planning is running.",
                    timestamp: now()
                )
            } else if purpose == .codingImplementation {
                Self.setCodingWorkflow(
                    in: &snapshot,
                    threadID: threadID,
                    state: .preparingImplementation,
                    reason: "The approved implementation is being prepared in an isolated worktree.",
                    timestamp: now()
                )
            }
            if !snapshot.operations.providerRuns.contains(where: {
                $0.threadID == threadID && $0.id != run.id && $0.state == .running
            }) {
                snapshot.threads[index].attention = .queued
            }
            snapshot.threads[index].updatedAtUnixMillis = now()
        }
        return persisted ? run.id : nil
    }

    public func nextQueuedProviderRun(threadID: String) -> DesktopProviderRunRecord? {
        snapshot.operations.providerRuns
            .filter { $0.threadID == threadID && $0.state == .proposed }
            .min { $0.startedAtUnixMillis < $1.startedAtUnixMillis }
    }

    public func beginProviderRun(id: String) -> DesktopProviderRunRecord? {
        var selected: DesktopProviderRunRecord?
        mutate { snapshot in
            guard let index = snapshot.operations.providerRuns.firstIndex(where: {
                $0.id == id && $0.state == .proposed
            }) else { return }
            snapshot.operations.providerRuns[index].state = .running
            snapshot.operations.providerRuns[index].costSummary = "Running"
            selected = snapshot.operations.providerRuns[index]
            if let threadID = selected?.threadID,
               let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
                snapshot.threads[threadIndex].attention = .running
                switch selected?.purpose {
                case .codingPlan:
                    snapshot.threads[threadIndex].summary = "Creating a read-only implementation plan…"
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID,
                        state: .planning,
                        reason: "Read-only implementation planning is running.",
                        timestamp: now()
                    )
                case .codingImplementation:
                    snapshot.threads[threadIndex].summary = "Implementing the approved plan in an isolated worktree…"
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID,
                        state: .implementing,
                        reason: "The approved plan is being implemented in an isolated worktree.",
                        timestamp: now()
                    )
                case .codingKnowledge:
                    snapshot.threads[threadIndex].summary = "Drafting the knowledge update…"
                case .conversation, nil:
                    snapshot.threads[threadIndex].summary = "Kaname is responding…"
                }
                snapshot.threads[threadIndex].updatedAtUnixMillis = now()
            }
        }
        return selected
    }

    public func attachNativeProviderRun(id: String, nativeThreadID: String, nativeTurnID: String?) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.providerRuns.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.providerRuns[index].nativeThreadID = nativeThreadID
            if let nativeTurnID {
                snapshot.operations.providerRuns[index].nativeTurnID = nativeTurnID
            }
            guard let threadID = snapshot.operations.providerRuns[index].threadID else { return }
            let provider = snapshot.operations.providerRuns[index].provider
            let sessionID = "session-\(Self.stableLocalDigest("\(provider)|\(nativeThreadID)"))"
            let descriptor = Self.providerSessionDescriptor(provider: provider)
            let session = DesktopProviderSessionRecord(
                id: sessionID,
                threadID: threadID,
                provider: provider,
                nativeSessionID: nativeThreadID,
                source: "Kaname native adapter",
                capabilities: descriptor.capabilities,
                limitations: descriptor.limitations,
                state: .running,
                lastReconciledAtUnixMillis: timestamp
            )
            if let sessionIndex = snapshot.operations.providerSessions.firstIndex(where: { $0.id == sessionID }) {
                snapshot.operations.providerSessions[sessionIndex] = session
            } else {
                snapshot.operations.providerSessions.append(session)
            }
        }
    }

    public func latestNativeThreadID(threadID: String, provider: String? = nil) -> String? {
        latestNativeThreadID(threadID: threadID, provider: provider, workspacePathOverride: nil, matchWorkspace: false)
    }

    /// Native provider sessions are bound to the directory they started in
    /// (Claude Code stores them per project path), so a run only resumes a
    /// session that was started in the same workspace.
    public func latestNativeThreadID(
        threadID: String,
        provider: String?,
        workspacePathOverride: String?,
        matchWorkspace: Bool = true
    ) -> String? {
        let compactedAt = thread(id: threadID)?.compaction?.createdAtUnixMillis
        return snapshot.operations.providerRuns
            .filter {
                guard $0.threadID == threadID, $0.nativeThreadID != nil else { return false }
                if let compactedAt = compactedAt, $0.startedAtUnixMillis < compactedAt { return false }
                if matchWorkspace, $0.workspacePathOverride != workspacePathOverride { return false }
                guard let provider else { return true }
                return $0.provider.caseInsensitiveCompare(provider) == .orderedSame
            }
            .max { $0.startedAtUnixMillis < $1.startedAtUnixMillis }?
            .nativeThreadID
    }

    @discardableResult
    public func recordProviderEvent(
        _ event: DesktopProviderEventRecord,
        assistantDelta: String? = nil
    ) -> Bool {
        recordProviderEvents([DesktopProviderEventBatchItem(event: event, assistantDelta: assistantDelta)])?
            .acceptedEventIDs.contains(event.id) == true
    }

    @discardableResult
    public func recordProviderEvents(
        _ items: [DesktopProviderEventBatchItem]
    ) -> DesktopProviderEventBatchResult? {
        guard items.count <= 64,
              items.allSatisfy({ item in
                  item.event.detail.utf8.count <= 65_536
                      && (item.event.rawPayloadBase64?.utf8.count ?? 0) <= 360_000
              }) else { return nil }
        guard items.allSatisfy({ item in
            guard let run = snapshot.operations.providerRuns.first(where: { $0.id == item.event.runID }) else { return false }
            return run.threadID == item.event.threadID
        }) else { return nil }
        guard !items.isEmpty else {
            return DesktopProviderEventBatchResult(acceptedEventIDs: [], duplicateEventIDs: [])
        }

        var batchEventIDs: Set<String> = []
        var acceptedItems: [DesktopProviderEventBatchItem] = []
        var duplicateEventIDs: [String] = []
        acceptedItems.reserveCapacity(items.count)
        for item in items {
            if !providerEventIDs.contains(item.event.id), batchEventIDs.insert(item.event.id).inserted {
                acceptedItems.append(item)
            } else {
                duplicateEventIDs.append(item.event.id)
            }
        }
        guard !acceptedItems.isEmpty else {
            return DesktopProviderEventBatchResult(acceptedEventIDs: [], duplicateEventIDs: duplicateEventIDs)
        }

        let persisted = mutate { snapshot in
            for item in acceptedItems {
                var event = item.event
                if let run = snapshot.operations.providerRuns.first(where: { $0.id == event.runID }) {
                    event.turnID = run.turnID
                }
                snapshot.operations.providerEvents.append(event)
                if event.kind == .approval {
                    if let index = snapshot.threads.firstIndex(where: { $0.id == event.threadID }) {
                        snapshot.threads[index].attention = event.title == "Approval requested" ? .needsApproval : .running
                    }
                } else if event.kind == .question {
                    if let index = snapshot.threads.firstIndex(where: { $0.id == event.threadID }) {
                        snapshot.threads[index].attention = event.title == "Question answered" ? .running : .needsInput
                    }
                }
                Self.applyAssistantDelta(item.assistantDelta, for: event, to: &snapshot)
            }
        }
        guard persisted else { return nil }
        providerEventIDs.formUnion(acceptedItems.map(\.event.id))
        return DesktopProviderEventBatchResult(
            acceptedEventIDs: acceptedItems.map(\.event.id),
            duplicateEventIDs: duplicateEventIDs
        )
    }

    private static func applyAssistantDelta(
        _ delta: String?,
        for event: DesktopProviderEventRecord,
        to snapshot: inout DesktopAppSnapshot
    ) {
        guard let delta, !delta.isEmpty,
              let threadIndex = snapshot.threads.firstIndex(where: { $0.id == event.threadID }) else { return }
        let messageID = "assistant-\(event.runID)"
        if let messageIndex = snapshot.threads[threadIndex].messages.firstIndex(where: { $0.id == messageID }) {
            let current = snapshot.threads[threadIndex].messages[messageIndex]
            snapshot.threads[threadIndex].messages[messageIndex] = DesktopMessage(
                id: current.id,
                turnID: event.turnID,
                role: .assistant,
                body: String((current.body + delta).prefix(262_144)),
                attachments: current.attachments,
                createdAtUnixMillis: current.createdAtUnixMillis
            )
        } else {
            snapshot.threads[threadIndex].messages.append(
                DesktopMessage(
                    id: messageID,
                    turnID: event.turnID,
                    role: .assistant,
                    body: String(delta.prefix(262_144)),
                    createdAtUnixMillis: event.createdAtUnixMillis
                )
            )
        }
        snapshot.threads[threadIndex].summary = "Kaname is responding…"
    }

    public func completeProviderRun(id: String, tokenUsage: Int? = nil) {
        finishProviderRun(id: id, outcome: .completed(tokenUsage))
    }

    public func stopProviderRun(id: String, interrupted: Bool, error: String) {
        finishProviderRun(id: id, outcome: .stopped(interrupted: interrupted, error: Self.normalized(error)))
    }

    private enum ProviderRunOutcome {
        case completed(Int?)
        case stopped(interrupted: Bool, error: String)
    }

    private func finishProviderRun(id: String, outcome: ProviderRunOutcome) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.providerRuns.firstIndex(where: { $0.id == id }) else { return }
            let sessionState: DesktopProviderSessionState
            let threadSummary: String
            let attention: DesktopAttention
            switch outcome {
            case let .completed(tokenUsage):
                snapshot.operations.providerRuns[index].state = .completed
                snapshot.operations.providerRuns[index].tokenUsage = tokenUsage
                snapshot.operations.providerRuns[index].costSummary = tokenUsage.map { "\($0) tokens" } ?? "Usage not reported"
                sessionState = .ready
                let threadID = snapshot.operations.providerRuns[index].threadID
                let assistant = snapshot.threads.first(where: { $0.id == threadID })?.messages.last(where: { $0.role == .assistant })?.body
                switch snapshot.operations.providerRuns[index].purpose {
                case .codingPlan:
                    attention = .needsApproval
                    threadSummary = "Plan ready. Approve it to start implementing, or keep refining in Chat."
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID ?? "",
                        state: .awaitingPlanApproval,
                        reason: "The read-only plan is ready for explicit approval.",
                        timestamp: timestamp
                    )
                case .codingImplementation:
                    attention = .needsApproval
                    threadSummary = "Implementation turn finished. Review Changes, run checks, or keep steering in Chat."
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID ?? "",
                        state: .awaitingReview,
                        reason: "Implementation finished; explicit review is required before independent evidence collection.",
                        timestamp: timestamp
                    )
                case .codingKnowledge:
                    attention = .needsApproval
                    threadSummary = "Knowledge update drafted. Review the proposed notes in the Knowledge tab."
                case .conversation:
                    attention = .needsResponse
                    threadSummary = assistant.map(Self.provisionalConversationTitle) ?? "Provider completed."
                }
            case let .stopped(interrupted, error):
                snapshot.operations.providerRuns[index].state = interrupted ? .interrupted : .failed
                snapshot.operations.providerRuns[index].errorSummary = error
                snapshot.operations.providerRuns[index].costSummary = interrupted ? "Interrupted" : "Failed"
                for subagentIndex in snapshot.operations.subagents.indices
                where snapshot.operations.subagents[subagentIndex].runID == id
                    && Self.isActiveSubagentState(snapshot.operations.subagents[subagentIndex].state) {
                    snapshot.operations.subagents[subagentIndex].state = interrupted ? .interrupted : .failed
                    snapshot.operations.subagents[subagentIndex].completedAtUnixMillis = timestamp
                }
                sessionState = interrupted ? .recoverable : .interrupted
                threadSummary = interrupted ? "Provider turn interrupted. You can retry it." : error
                attention = interrupted ? .needsResponse : .failed
                if snapshot.operations.providerRuns[index].purpose != .conversation,
                   let threadID = snapshot.operations.providerRuns[index].threadID {
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID,
                        state: .failed,
                        reason: threadSummary,
                        timestamp: timestamp
                    )
                }
            }
            snapshot.operations.providerRuns[index].completedAtUnixMillis = timestamp
            Self.reconcileProviderSession(
                snapshot: &snapshot,
                runIndex: index,
                state: sessionState,
                timestamp: timestamp
            )
            guard let threadID = snapshot.operations.providerRuns[index].threadID,
                  let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[threadIndex].summary = threadSummary
            snapshot.threads[threadIndex].attention = attention
            snapshot.threads[threadIndex].unread = true
            snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
        }
    }

    public func recoverOrphanedProviderRuns() {
        let hasOrphanedProviderRun = snapshot.operations.providerRuns.contains { $0.state == .running }
        let hasOrphanedSubagent = snapshot.operations.subagents.contains { Self.isActiveSubagentState($0.state) }
        guard hasOrphanedProviderRun || hasOrphanedSubagent else { return }
        let timestamp = now()
        mutate { snapshot in
            let orphaned = snapshot.operations.providerRuns.indices.filter {
                snapshot.operations.providerRuns[$0].state == .running
            }
            for index in orphaned {
                snapshot.operations.providerRuns[index].state = .interrupted
                snapshot.operations.providerRuns[index].errorSummary = "The UI or provider stopped before completion. Resume or retry from the durable conversation."
                snapshot.operations.providerRuns[index].costSummary = "Reconnect required"
                snapshot.operations.providerRuns[index].completedAtUnixMillis = timestamp
                if let threadID = snapshot.operations.providerRuns[index].threadID,
                   let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
                    snapshot.threads[threadIndex].attention = .needsResponse
                    snapshot.threads[threadIndex].summary = "A provider turn needs recovery. No message was duplicated."
                    if snapshot.operations.providerRuns[index].purpose != .conversation {
                        Self.setCodingWorkflow(
                            in: &snapshot,
                            threadID: threadID,
                            state: .failed,
                            reason: "The coding provider stopped before completion; no result was accepted.",
                            timestamp: timestamp
                        )
                    }
                }
            }
            Self.interruptActiveSubagents(in: &snapshot, threadID: nil, timestamp: timestamp)
        }
    }

    private static func isActiveSubagentState(_ state: DesktopSubagentState) -> Bool {
        [.queued, .running, .waiting].contains(state)
    }

    private static func interruptActiveSubagents(
        in snapshot: inout DesktopAppSnapshot,
        threadID: String?,
        timestamp: Int64
    ) {
        for subagentIndex in snapshot.operations.subagents.indices
        where (threadID == nil || snapshot.operations.subagents[subagentIndex].threadID == threadID)
            && Self.isActiveSubagentState(snapshot.operations.subagents[subagentIndex].state) {
            snapshot.operations.subagents[subagentIndex].state = .interrupted
            snapshot.operations.subagents[subagentIndex].completedAtUnixMillis = timestamp
        }
    }

    private static func reconcileProviderSession(
        snapshot: inout DesktopAppSnapshot,
        runIndex: Int,
        state: DesktopProviderSessionState,
        timestamp: Int64
    ) {
        let run = snapshot.operations.providerRuns[runIndex]
        guard let nativeID = run.nativeThreadID,
              let sessionIndex = snapshot.operations.providerSessions.firstIndex(where: {
                  $0.nativeSessionID == nativeID
                      && $0.provider.caseInsensitiveCompare(run.provider) == .orderedSame
              }) else { return }
        snapshot.operations.providerSessions[sessionIndex].state = state
        snapshot.operations.providerSessions[sessionIndex].lastReconciledAtUnixMillis = timestamp
    }

    @discardableResult
    public func retryProviderRun(id: String) -> String? {
        guard let run = providerRun(id: id), let threadID = run.threadID, let sourceMessageID = run.sourceMessageID,
              [.failed, .interrupted].contains(run.state), run.purpose != .codingImplementation else { return nil }
        return enqueueProviderRun(
            threadID: threadID,
            sourceMessageID: sourceMessageID,
            usesProjectContext: run.usesProjectContext ?? true,
            workspacePathOverride: run.workspacePathOverride,
            purpose: run.purpose,
            runtimeModeOverride: run.runtimeMode,
            networkAccessOverride: run.networkAccess
        )
    }

    public func addProviderPlan(threadID: String, text: String, completed: Bool) {
        let clean = Self.normalized(text)
        guard !clean.isEmpty else { return }
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            let item = DesktopPlanItem(
                id: "provider-plan-\(Self.stableLocalDigest(clean).prefix(16))",
                title: String(clean.prefix(2_000)),
                state: completed ? .complete : .inProgress
            )
            if let itemIndex = snapshot.threads[index].plan.firstIndex(where: { $0.id == item.id }) {
                snapshot.threads[index].plan[itemIndex] = item
            } else {
                snapshot.threads[index].plan.append(item)
            }
        }
    }

    /// Appends findings parsed from a provider reply, skipping duplicates.
    public func appendFindings(threadID: String, runID: String?, texts: [String]) {
        let timestamp = now()
        let items = texts.compactMap { raw -> DesktopFinding? in
            let clean = Self.normalized(raw)
            guard !clean.isEmpty else { return nil }
            let firstSentence = clean.split(whereSeparator: { $0 == "\n" || $0 == "." }).first.map(String.init) ?? clean
            return DesktopFinding(
                id: "finding-\(Self.stableLocalDigest(clean).prefix(16))",
                title: String(firstSentence.prefix(140)),
                detail: String(clean.prefix(4_000)),
                runID: runID,
                createdAtUnixMillis: timestamp
            )
        }
        guard !items.isEmpty else { return }
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            var existing = snapshot.threads[index].findings ?? []
            let known = Set(existing.map(\.id))
            existing += items.filter { !known.contains($0.id) }
            snapshot.threads[index].findings = Array(existing.suffix(200))
            snapshot.threads[index].updatedAtUnixMillis = timestamp
        }
    }

    /// Records a note the provider proposed through the Kaname Bridge.
    public func addKnowledgeNoteProposal(threadID: String, runID: String?, path: String, content: String, rationale: String) {
        let timestamp = now()
        guard let thread = thread(id: threadID), thread.kind == .coding else { return }
        let proposal = DesktopKnowledgeNoteProposal(
            id: "note-proposal-\(Self.stableLocalDigest(path + "\u{0}" + content).prefix(16))",
            path: path,
            content: String(content.prefix(256 * 1_024)),
            rationale: String(rationale.prefix(4_000)),
            runID: runID,
            createdAtUnixMillis: timestamp
        )
        mutate { snapshot in
            guard let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            if let laneIndex = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }) {
                var proposals = snapshot.operations.codingKnowledgeLanes[laneIndex].noteProposals ?? []
                proposals.removeAll { $0.path == proposal.path }
                proposals.append(proposal)
                snapshot.operations.codingKnowledgeLanes[laneIndex].noteProposals = Array(proposals.suffix(20))
                snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            } else {
                var lane = DesktopCodingKnowledgeLane(
                    projectID: snapshot.threads[threadIndex].projectID,
                    threadID: threadID,
                    createdAtUnixMillis: timestamp,
                    updatedAtUnixMillis: timestamp
                )
                lane.noteProposals = [proposal]
                snapshot.operations.codingKnowledgeLanes.append(lane)
            }
            snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
        }
    }

    /// Stores the full Markdown plan body shown above the step outline.
    public func setProviderPlanBody(threadID: String, text: String?) {
        let clean = text.map(Self.normalized) ?? ""
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].planBody = clean.isEmpty ? nil : String(clean.prefix(64 * 1_024))
            snapshot.threads[index].updatedAtUnixMillis = now()
        }
    }

    public func replaceProviderPlan(
        threadID: String,
        steps: [(title: String, status: String)],
        explanation: String?
    ) {
        let items = steps.enumerated().map { index, entry in
            let status = entry.status.lowercased().replacingOccurrences(of: "_", with: "")
            let state: DesktopPlanItem.State = switch status {
            case "completed", "complete": .complete
            case "inprogress": .inProgress
            default: .pending
            }
            return DesktopPlanItem(
                id: "provider-plan-\(index)-\(Self.stableLocalDigest(entry.title).prefix(16))",
                title: entry.title,
                state: state
            )
        }
        guard !items.isEmpty else { return }
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].plan = items
            if let explanation {
                snapshot.threads[index].summary = explanation
            }
            snapshot.threads[index].updatedAtUnixMillis = now()
        }
    }

    public func markCodingPlanUnavailable(threadID: String) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].attention = .failed
            snapshot.threads[index].summary = "The planning turn ended without a readable plan. Ask again or rephrase."
            snapshot.threads[index].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .failed,
                reason: "The planning turn completed without a readable plan.",
                timestamp: timestamp
            )
        }
    }

    public func finalizeCodingPlanForApproval(threadID: String) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            for planIndex in snapshot.threads[index].plan.indices { snapshot.threads[index].plan[planIndex].state = .pending }
            snapshot.threads[index].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .awaitingPlanApproval,
                reason: "The plan is ready for explicit approval.",
                timestamp: timestamp
            )
        }
    }

    @discardableResult
    public func recordCodingEvidence(
        threadID: String,
        worktreeID: String,
        revision: String,
        diffStat: String,
        diffCheckPassed: Bool,
        verificationCommand: String,
        verificationExitStatus: Int32,
        verificationOutput: String,
        artifactPaths: [String],
        digest: String,
        verificationWasRun: Bool = true
    ) -> Bool {
        guard let currentThread = thread(id: threadID), currentThread.kind == .coding,
              codingWorkflow(threadID: threadID)?.state == .reviewingEvidence,
              snapshot.operations.worktrees.contains(where: {
                  $0.id == worktreeID && $0.threadID == threadID && ($0.state == .ready || $0.state == .review)
              }) else { return false }
        let changedFilesState: DesktopEvidence.State = artifactPaths.isEmpty ? .failed : .passed
        let testState: DesktopEvidence.State = !verificationWasRun ? .notRun : (verificationExitStatus == 0 ? .passed : .failed)
        let diffState: DesktopEvidence.State = diffCheckPassed ? .passed : .failed
        let evidencePassed = diffCheckPassed && (!verificationWasRun || verificationExitStatus == 0) && !artifactPaths.isEmpty
        let items = [
            DesktopEvidence(
                id: "coding-diff-\(worktreeID)",
                label: "Diff integrity",
                detail: diffStat.isEmpty ? "No changed files were found." : diffStat,
                state: diffState
            ),
            DesktopEvidence(
                id: "coding-tests-\(worktreeID)",
                label: verificationCommand,
                detail: String((verificationOutput.isEmpty ? "No command output." : verificationOutput).suffix(4_000)),
                state: testState
            ),
            DesktopEvidence(
                id: "coding-files-\(worktreeID)",
                label: "Changed files",
                detail: artifactPaths.isEmpty ? "No implementation changes were produced." : artifactPaths.joined(separator: ", "),
                state: changedFilesState
            ),
            DesktopEvidence(
                id: "coding-revision-\(worktreeID)",
                label: "Evidence digest",
                detail: digest,
                state: evidencePassed ? .passed : .failed
            ),
        ]
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            guard let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  snapshot.threads[threadIndex].kind == .coding,
                  snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .reviewingEvidence,
                  let worktreeIndex = snapshot.operations.worktrees.firstIndex(where: {
                      $0.id == worktreeID && $0.threadID == threadID && ($0.state == .ready || $0.state == .review)
                  }) else { return }
            snapshot.threads[threadIndex].evidence = items
            snapshot.threads[threadIndex].attention = .needsApproval
            snapshot.threads[threadIndex].summary = evidencePassed
                ? "Evidence is ready. Review and accept or reject the implementation."
                : "Evidence found a failure. Review it before deciding what to do."
            if evidencePassed {
                for index in snapshot.threads[threadIndex].plan.indices {
                    snapshot.threads[threadIndex].plan[index].state = .complete
                }
            }
            snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
            snapshot.operations.worktrees[worktreeIndex].headRevision = revision
            snapshot.operations.worktrees[worktreeIndex].changedFileCount = artifactPaths.count
            snapshot.operations.worktrees[worktreeIndex].diffSummary = String(diffStat.prefix(32_000))
            snapshot.operations.worktrees[worktreeIndex].testCommand = verificationCommand
            snapshot.operations.worktrees[worktreeIndex].testSummary = String(verificationOutput.suffix(32_000))
            snapshot.operations.worktrees[worktreeIndex].diagnosticSummary = "Evidence digest \(digest)"
            snapshot.operations.worktrees[worktreeIndex].state = .review
            snapshot.operations.worktrees[worktreeIndex].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: evidencePassed ? .awaitingAcceptance : .reviewingEvidence,
                reason: evidencePassed
                    ? "Independent evidence passed; accept or reject the implementation."
                    : "Independent evidence contains a failure and requires review.",
                timestamp: timestamp
            )
            didApply = true
        }
        return didApply && persisted
    }

    @discardableResult
    public func recordCodingReview(threadID: String, worktreeID: String, accepted: Bool) -> Bool {
        let currentWorkflowState = codingWorkflow(threadID: threadID)?.state
        let reviewStateIsValid = accepted
            ? currentWorkflowState == .awaitingAcceptance
            : currentWorkflowState == .awaitingAcceptance || currentWorkflowState == .reviewingEvidence
        guard let currentThread = thread(id: threadID), currentThread.kind == .coding,
              reviewStateIsValid,
              snapshot.operations.worktrees.contains(where: {
                  $0.id == worktreeID && $0.threadID == threadID && $0.state == .review
              }) else { return false }
        if accepted {
            guard !currentThread.evidence.isEmpty,
                  currentThread.evidence.allSatisfy({ $0.state == .passed || $0.state == .notRun }) else { return false }
        }
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            let persistedWorkflowState = snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state
            let persistedReviewStateIsValid = accepted
                ? persistedWorkflowState == .awaitingAcceptance
                : persistedWorkflowState == .awaitingAcceptance || persistedWorkflowState == .reviewingEvidence
            guard let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  snapshot.threads[threadIndex].kind == .coding,
                  persistedReviewStateIsValid,
                  let worktreeIndex = snapshot.operations.worktrees.firstIndex(where: {
                      $0.id == worktreeID && $0.threadID == threadID && $0.state == .review
                  }) else { return }
            if accepted {
                guard !snapshot.threads[threadIndex].evidence.isEmpty,
                      snapshot.threads[threadIndex].evidence.allSatisfy({ $0.state == .passed || $0.state == .notRun }) else { return }
            }
            snapshot.operations.worktrees[worktreeIndex].state = accepted ? .accepted : .dirty
            snapshot.operations.worktrees[worktreeIndex].updatedAtUnixMillis = timestamp
            snapshot.threads[threadIndex].attention = accepted ? .needsApproval : .needsResponse
            snapshot.threads[threadIndex].summary = accepted
                ? "Accepted. Drafting the knowledge update; nothing was pushed."
                : "Implementation rejected. The isolated changes remain available for revision."
            snapshot.threads[threadIndex].unread = false
            snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: accepted ? .updatingKnowledge : .rejected,
                reason: accepted
                    ? "Implementation accepted locally; review, reconcile, or waive the knowledge lane."
                    : "The implementation was rejected and remains available for revision.",
                timestamp: timestamp
            )
            if accepted {
                if let laneIndex = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }) {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].acceptedWorktreeID = worktreeID
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .needsReview
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "Implementation was accepted locally; knowledge disposition is pending review."
                    snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
                } else {
                    snapshot.operations.codingKnowledgeLanes.append(.init(
                        projectID: snapshot.threads[threadIndex].projectID,
                        threadID: threadID,
                        disposition: .needsReview,
                        dispositionReason: "Implementation was accepted locally; knowledge disposition is pending review.",
                        acceptedWorktreeID: worktreeID,
                        createdAtUnixMillis: timestamp,
                        updatedAtUnixMillis: timestamp
                    ))
                }
            }
            didApply = true
        }
        return didApply && persisted
    }

    private func providerContextReferenceCount(for thread: DesktopThread) -> Int {
        guard let project = project(id: thread.projectID) else { return 0 }
        return project.context.instructionReferences.count
            + project.context.knowledgeSourceIDs.count
            + project.context.skillIDs.count
    }

    public func setAttention(threadID: String, attention: DesktopAttention) {
        mutateThread(id: threadID) { thread in
            thread.attention = attention
            thread.updatedAtUnixMillis = now()
            if attention == .completed || attention == .archived {
                thread.unread = false
            }
        }
    }

    public func markRead(threadID: String) {
        mutateThread(id: threadID) { $0.unread = false }
    }

    @discardableResult
    public func createProject(
        name: String,
        path: String?,
        summary: String,
        context: DesktopProjectContext = .empty
    ) -> String? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf8.count <= 120,
              cleanSummary.utf8.count <= 2_000 else { return nil }
        let cleanPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedPath = cleanPath?.isEmpty == false ? Self.canonicalProjectPath(cleanPath!) : nil
        guard storedPath?.utf8.count ?? 0 <= 4_096,
              !snapshot.projects.contains(where: { project in
                  guard let existing = project.path else { return false }
                  return Self.canonicalProjectPath(existing) == storedPath
              }) else { return nil }
        let instructionReferences = Self.uniqueNormalized(
            context.instructionReferences,
            maximumCount: 24,
            maximumBytes: 1_024
        )
        let knowledgeIDs = Set(snapshot.domains.knowledgeSources.map(\.id))
        let skillIDs = Set(snapshot.domains.skills.map(\.id))
        let provider = Self.normalized(context.defaultProvider)
        let model = Self.normalized(context.defaultModel)
        guard !provider.isEmpty, provider.utf8.count <= 120,
              !model.isEmpty, model.utf8.count <= 200 else { return nil }
        let project = DesktopProject(
            name: cleanName,
            path: storedPath,
            summary: cleanSummary,
            context: DesktopProjectContext(
                instructionReferences: instructionReferences,
                knowledgeSourceIDs: Self.unique(context.knowledgeSourceIDs.filter(knowledgeIDs.contains)),
                skillIDs: Self.unique(context.skillIDs.filter(skillIDs.contains)),
                defaultKind: context.defaultKind,
                defaultProvider: provider,
                defaultModel: model
            ),
            createdAtUnixMillis: now()
        )
        mutate { $0.projects.append(project) }
        return project.id
    }

    private static func canonicalProjectPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    @discardableResult
    public func updateProject(
        id: String,
        name: String,
        path: String?,
        summary: String,
        context: DesktopProjectContext
    ) -> Bool {
        let cleanName = Self.normalized(name)
        let cleanSummary = Self.normalized(summary)
        let cleanPath = path.map(Self.normalized)
        let instructions = Self.uniqueNormalized(context.instructionReferences, maximumCount: 24, maximumBytes: 1_024)
        let knowledgeIDs = Set(snapshot.domains.knowledgeSources.map(\.id))
        let skillIDs = Set(snapshot.domains.skills.map(\.id))
        let provider = Self.normalized(context.defaultProvider)
        let model = Self.normalized(context.defaultModel)
        guard snapshot.projects.contains(where: { $0.id == id }),
              !cleanName.isEmpty, cleanName.utf8.count <= 120,
              cleanSummary.utf8.count <= 2_000,
              cleanPath?.utf8.count ?? 0 <= 4_096,
              !provider.isEmpty, provider.utf8.count <= 120,
              !model.isEmpty, model.utf8.count <= 200 else { return false }
        let sanitizedContext = DesktopProjectContext(
            instructionReferences: instructions,
            knowledgeSourceIDs: Self.unique(context.knowledgeSourceIDs.filter(knowledgeIDs.contains)),
            skillIDs: Self.unique(context.skillIDs.filter(skillIDs.contains)),
            defaultKind: context.defaultKind,
            defaultProvider: provider,
            defaultModel: model
        )
        mutate { snapshot in
            guard let index = snapshot.projects.firstIndex(where: { $0.id == id }) else { return }
            snapshot.projects[index].name = cleanName
            snapshot.projects[index].path = cleanPath?.isEmpty == false ? cleanPath : nil
            snapshot.projects[index].summary = cleanSummary
            snapshot.projects[index].context = sanitizedContext
        }
        return true
    }

    public func setProjectArchived(id: String, archived: Bool) {
        mutate { snapshot in
            guard let index = snapshot.projects.firstIndex(where: { $0.id == id }) else { return }
            snapshot.projects[index].archivedAtUnixMillis = archived ? now() : nil
            if archived {
                for threadIndex in snapshot.threads.indices where snapshot.threads[threadIndex].projectID == id {
                    snapshot.threads[threadIndex].attention = .archived
                    snapshot.threads[threadIndex].unread = false
                }
            }
        }
    }

    public func updatePreferences(_ preferences: DesktopPreferences) {
        mutate { $0.preferences = preferences }
    }

    public func replaceAccounts(
        for services: Set<DesktopAccountRecord.Service>,
        with accounts: [DesktopAccountRecord]
    ) {
        guard accounts.allSatisfy({ services.contains($0.service) }) else { return }
        mutate { snapshot in
            snapshot.domains.accounts.removeAll { services.contains($0.service) }
            snapshot.domains.accounts.append(contentsOf: accounts)
            snapshot.domains.accounts = Self.sortedRecords(snapshot.domains.accounts) {
                "\($0.service.rawValue)|\($0.identity)"
            }
        }
    }

    public func replaceCalendarSources(_ sources: [DesktopCalendarSourceRecord]) {
        let priorEnablement = Dictionary(
            uniqueKeysWithValues: snapshot.domains.calendarSources.map { ($0.id, $0.isEnabled) }
        )
        mutate { snapshot in
            let merged = sources.map { source in
                var updated = source
                updated.isEnabled = priorEnablement[source.id] ?? source.isEnabled
                return updated
            }
            let deduplicated = Dictionary(grouping: merged) {
                "\($0.provider.rawValue)|\($0.accountID)|\($0.externalIdentifier)".lowercased()
            }.compactMap { $0.value.last }
            snapshot.domains.calendarSources = Self.sortedRecords(deduplicated) {
                "\($0.provider.rawValue)|\($0.displayName)"
            }
        }
    }

    public func setCalendarSourceEnabled(id: String, enabled: Bool) {
        mutateRecord(at: \.domains.calendarSources, id: id) { source in
            source.isEnabled = enabled
        }
    }

    @discardableResult
    public func createResearch(title: String, question: String) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanQuestion.isEmpty,
              cleanTitle.utf8.count <= 160, cleanQuestion.utf8.count <= 4_000 else { return nil }
        let record = DesktopResearchRecord(
            id: UUID().uuidString.lowercased(),
            title: cleanTitle,
            question: cleanQuestion,
            status: .draft,
            sourceCount: 0,
            updatedAtUnixMillis: now()
        )
        mutate { $0.domains.research.append(record) }
        return record.id
    }

    @discardableResult
    public func saveEmailDraft(
        id: String? = nil,
        accountID: String?,
        recipients: String,
        subject: String,
        body: String
    ) -> String? {
        let cleanSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSubject.isEmpty || !cleanBody.isEmpty,
              cleanSubject.utf8.count <= 998, cleanBody.utf8.count <= 100_000 else { return nil }
        let draft = DesktopEmailDraft(
            id: id ?? UUID().uuidString.lowercased(),
            accountID: accountID,
            recipients: recipients.trimmingCharacters(in: .whitespacesAndNewlines),
            subject: cleanSubject,
            body: cleanBody,
            status: .draft,
            updatedAtUnixMillis: now()
        )
        mutate { snapshot in
            if let index = snapshot.domains.emailDrafts.firstIndex(where: { $0.id == draft.id }) {
                snapshot.domains.emailDrafts[index] = draft
            } else {
                snapshot.domains.emailDrafts.append(draft)
            }
        }
        return draft.id
    }

    @discardableResult
    public func recordMailAction(
        accountID: String,
        accountIdentity: String,
        threadID: String?,
        kind: DesktopMailActionRecord.Kind,
        preview: String,
        exactTarget: String,
        standingRuleID: String? = nil
    ) -> String? {
        let cleanPreview = Self.normalized(preview)
        let cleanTarget = Self.normalized(exactTarget)
        guard !accountID.isEmpty, !accountIdentity.isEmpty, !cleanPreview.isEmpty, !cleanTarget.isEmpty,
              cleanPreview.utf8.count <= 8_192, cleanTarget.utf8.count <= 2_048 else { return nil }
        let action = DesktopMailActionRecord(
            id: UUID().uuidString.lowercased(),
            accountID: accountID,
            accountIdentity: accountIdentity,
            threadID: threadID,
            kind: kind,
            preview: cleanPreview,
            exactTarget: cleanTarget,
            approvalID: nil,
            standingRuleID: standingRuleID,
            state: standingRuleID == nil ? .proposed : .approved,
            remoteReceipt: nil,
            createdAtUnixMillis: now(),
            reconciledAtUnixMillis: nil
        )
        mutate { $0.operations.mailActions.append(action) }
        return action.id
    }

    public func attachMailApproval(actionID: String, approvalID: String) {
        mutateRecord(at: \.operations.mailActions, id: actionID) { action in
            action.approvalID = approvalID
            action.state = .awaitingApproval
        }
    }

    public func reconcileMailAction(id: String, state: DesktopActionState, remoteReceipt: String?) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.mailActions.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.mailActions[index].state = state
            snapshot.operations.mailActions[index].remoteReceipt = remoteReceipt
            snapshot.operations.mailActions[index].reconciledAtUnixMillis = timestamp
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "gmail",
                action: snapshot.operations.mailActions[index].kind.rawValue,
                target: snapshot.operations.mailActions[index].exactTarget,
                state: state,
                detail: remoteReceipt ?? "Remote reconciliation did not complete.",
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    public func resumableMailAction(
        accountID: String,
        threadID: String,
        exactTarget: String
    ) -> DesktopMailActionRecord? {
        snapshot.operations.mailActions
            .filter {
                $0.accountID == accountID
                    && $0.threadID == threadID
                    && $0.exactTarget == exactTarget
                    && $0.standingRuleID == nil
                    && ($0.state == .proposed || $0.state == .awaitingApproval)
            }
            .compactMap { action -> (record: DesktopMailActionRecord, priority: Int)? in
                guard let approvalID = action.approvalID else {
                    return action.state == .proposed ? (action, 0) : nil
                }
                guard action.state == .awaitingApproval,
                      let approval = snapshot.operations.approvals.first(where: { $0.id == approvalID }),
                      approval.exactTarget == action.exactTarget else { return nil }
                switch approval.state {
                case .approved:
                    return (action, 2)
                case .awaitingApproval:
                    return (action, 1)
                default:
                    return nil
                }
            }
            .max {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.record.createdAtUnixMillis < $1.record.createdAtUnixMillis
            }?
            .record
    }

    @discardableResult
    public func createMailStandingRule(
        accountID: String,
        accountIdentity: String,
        name: String,
        query: String,
        action: DesktopMailActionRecord.Kind
    ) -> String? {
        let cleanName = Self.normalized(name)
        let cleanQuery = Self.normalized(query)
        guard !accountID.isEmpty, !accountIdentity.isEmpty, !cleanName.isEmpty, !cleanQuery.isEmpty,
              action == .archive || action == .labels else { return nil }
        let rule = DesktopMailStandingRule(
            id: UUID().uuidString.lowercased(),
            accountID: accountID,
            accountIdentity: accountIdentity,
            name: cleanName,
            query: cleanQuery,
            action: action,
            enabled: true,
            createdAtUnixMillis: now()
        )
        mutate { $0.operations.mailStandingRules.append(rule) }
        return rule.id
    }

    public func setMailStandingRuleEnabled(id: String, enabled: Bool) {
        mutate { snapshot in
            guard let index = snapshot.operations.mailStandingRules.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.mailStandingRules[index].enabled = enabled
        }
    }

    public func replaceMailAttention(_ records: [DesktopMailAttentionRecord]) {
        mutate { $0.operations.mailAttention = records }
    }

    public func reconcileMailAttention(
        _ entries: [(accountID: String, threadID: String, accountIdentity: String, sender: String, subject: String, unread: Bool)]
    ) {
        let timestamp = now()
        mutate { snapshot in
            snapshot.operations.mailAttention = entries.map {
                DesktopMailAttentionRecord(
                    accountID: $0.accountID,
                    threadID: $0.threadID,
                    accountIdentity: $0.accountIdentity,
                    sender: $0.sender,
                    subject: $0.subject,
                    unread: $0.unread,
                    updatedAtUnixMillis: timestamp
                )
            }
        }
    }

    public func markEmailDraft(id: String, status: DesktopRecordState) {
        mutateRecord(at: \.domains.emailDrafts, id: id) { draft in
            draft.status = status
            draft.updatedAtUnixMillis = now()
        }
    }

    @discardableResult
    public func createCalendarProposal(
        accountID: String? = nil,
        calendarSourceID: String? = nil,
        title: String,
        startAtUnixMillis: Int64,
        durationMinutes: Int,
        timeZoneIdentifier: String,
        recurrence: String,
        isAllDay: Bool = false,
        mutationKind: DesktopCalendarProposal.MutationKind = .create,
        eventExternalID: String? = nil,
        seriesMasterExternalID: String? = nil,
        eventRevision: String? = nil,
        originalTitle: String? = nil,
        originalStartAtUnixMillis: Int64? = nil,
        originalEndAtUnixMillis: Int64? = nil,
        originalTimeZoneIdentifier: String? = nil,
        originalRecurrence: [String]? = nil,
        originalIsAllDay: Bool? = nil,
        seriesMasterRevision: String? = nil,
        seriesMasterRecurrence: [String]? = nil,
        seriesMasterStartAtUnixMillis: Int64? = nil,
        recurrenceScope: String? = nil
    ) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= 200,
              (1...10_080).contains(durationMinutes),
              TimeZone(identifier: timeZoneIdentifier) != nil else { return nil }
        var proposal = DesktopCalendarProposal(
            id: UUID().uuidString.lowercased(),
            accountID: accountID,
            calendarSourceID: calendarSourceID,
            title: cleanTitle,
            startAtUnixMillis: startAtUnixMillis,
            durationMinutes: durationMinutes,
            timeZoneIdentifier: timeZoneIdentifier,
            recurrence: recurrence.trimmingCharacters(in: .whitespacesAndNewlines),
            status: .proposed
        )
        proposal.mutationKind = mutationKind
        proposal.isAllDay = isAllDay
        proposal.eventExternalID = eventExternalID
        proposal.seriesMasterExternalID = seriesMasterExternalID
        proposal.eventRevision = eventRevision
        proposal.originalTitle = originalTitle
        proposal.originalStartAtUnixMillis = originalStartAtUnixMillis
        proposal.originalEndAtUnixMillis = originalEndAtUnixMillis
        proposal.originalTimeZoneIdentifier = originalTimeZoneIdentifier
        proposal.originalRecurrence = originalRecurrence
        proposal.originalIsAllDay = originalIsAllDay
        proposal.seriesMasterRevision = seriesMasterRevision
        proposal.seriesMasterRecurrence = seriesMasterRecurrence
        proposal.seriesMasterStartAtUnixMillis = seriesMasterStartAtUnixMillis
        proposal.recurrenceScope = recurrenceScope
        proposal.mutationPhase = "prepared"
        mutate { $0.domains.calendarProposals.append(proposal) }
        return proposal.id
    }

    public func prepareCalendarProposal(id: String, exactTarget: String) {
        mutateRecord(at: \.domains.calendarProposals, id: id) { proposal in
            proposal.exactTarget = String(exactTarget.prefix(2_048))
            proposal.approvalID = nil
            proposal.remoteReceipt = nil
            proposal.reconciledAtUnixMillis = nil
            proposal.mutationPhase = "prepared"
            proposal.status = .needsReview
        }
    }

    public func attachCalendarApproval(proposalID: String, approvalID: String) {
        mutateRecord(at: \.domains.calendarProposals, id: proposalID) { proposal in
            proposal.approvalID = approvalID
            proposal.status = .waiting
        }
    }

    public func beginCalendarProposalExecution(id: String) -> Bool {
        guard let proposal = snapshot.domains.calendarProposals.first(where: { $0.id == id }),
              proposal.status == .waiting || proposal.status == .running,
              let approvalID = proposal.approvalID,
              let exactTarget = proposal.exactTarget,
              exactEffectIsAuthorized(approvalID: approvalID, target: exactTarget) else { return false }
        mutateRecord(at: \.domains.calendarProposals, id: id) { $0.status = .running }
        return true
    }

    public func recordCalendarMutationPhase(id: String, phase: String) {
        mutateRecord(at: \.domains.calendarProposals, id: id) {
            $0.mutationPhase = String(phase.prefix(80))
            $0.status = .running
        }
    }

    public func recordCalendarMutationUncertain(id: String, detail: String) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.domains.calendarProposals.firstIndex(where: { $0.id == id }) else { return }
            snapshot.domains.calendarProposals[index].status = .running
            snapshot.domains.calendarProposals[index].remoteReceipt = "Outcome unknown. Reconcile before retrying: \(String(detail.prefix(8_000)))"
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "calendar",
                action: "reconcile-required",
                target: snapshot.domains.calendarProposals[index].exactTarget ?? "calendar proposal \(id)",
                state: .running,
                detail: "A calendar request may have reached the provider. Kaname retained the operation identity and stopped until its remote postconditions are reconciled.",
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    public func reconcileCalendarProposal(id: String, state: DesktopActionState, receipt: String) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.domains.calendarProposals.firstIndex(where: { $0.id == id }) else { return }
            snapshot.domains.calendarProposals[index].status = state == .reconciled ? .ready : .failed
            if state == .reconciled {
                snapshot.domains.calendarProposals[index].mutationPhase = "complete"
            }
            snapshot.domains.calendarProposals[index].remoteReceipt = String(receipt.prefix(8_192))
            snapshot.domains.calendarProposals[index].reconciledAtUnixMillis = timestamp
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "calendar",
                action: snapshot.domains.calendarProposals[index].mutationKind?.rawValue ?? "create",
                target: snapshot.domains.calendarProposals[index].exactTarget ?? "calendar proposal \(id)",
                state: state,
                detail: String(receipt.prefix(8_192)),
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    @discardableResult
    public func createAutomation(
        name: String,
        schedule: String,
        timeZoneIdentifier: String,
        actionSummary: String,
        missedRunPolicy: DesktopAutomationRule.MissedRunPolicy,
        scheduleSpec: DesktopScheduleSpec? = nil,
        actionKind: DesktopAutomationActionKind? = nil,
        authority: DesktopAutomationAuthority? = nil,
        projectID: String? = nil,
        skillIDs: [String] = [],
        toolNames: [String] = [],
        notificationEnabled: Bool = true
    ) -> String? {
        let fields = [name, schedule, actionSummary].map(Self.normalized)
        guard fields.allSatisfy({ !$0.isEmpty }),
              TimeZone(identifier: timeZoneIdentifier) != nil else { return nil }
        var rule = DesktopAutomationRule(
            id: UUID().uuidString.lowercased(),
            name: fields[0],
            schedule: fields[1],
            timeZoneIdentifier: timeZoneIdentifier,
            actionSummary: fields[2],
            missedRunPolicy: missedRunPolicy,
            status: .draft,
            nextRunAtUnixMillis: nil,
            lastResult: "Not run",
            createdAtUnixMillis: now()
        )
        rule.scheduleSpec = scheduleSpec
        rule.actionKind = actionKind
        rule.authority = authority
        rule.projectID = projectID
        rule.skillIDs = Array(Set(skillIDs)).sorted()
        rule.toolNames = Array(Set(toolNames.map(Self.normalized).filter { !$0.isEmpty })).sorted()
        rule.notificationEnabled = notificationEnabled
        mutate { $0.domains.automations.append(rule) }
        return rule.id
    }

    public func activateAutomation(id: String, approvalID: String?) -> Bool {
        guard let rule = snapshot.domains.automations.first(where: { $0.id == id }),
              let spec = rule.scheduleSpec,
              rule.actionKind != nil,
              rule.authority != nil,
              !(rule.actionKind != .notification && rule.authority == .localOnly),
              (rule.toolNames ?? []).isEmpty,
              (rule.actionKind != .skill || !(rule.skillIDs ?? []).isEmpty),
              (rule.skillIDs ?? []).allSatisfy({ skillID in
                  snapshot.domains.skills.contains { $0.id == skillID && $0.enabled }
              }) else { return false }
        if rule.authority != .localOnly {
            guard let approvalID, let target = automationAuthorityTarget(for: rule),
                  isApprovalGranted(id: approvalID, exactTarget: target) else { return false }
        }
        let timestamp = now()
        guard let next = try? DesktopScheduleEngine.nextOccurrence(
            spec: spec,
            timeZoneIdentifier: rule.timeZoneIdentifier,
            after: timestamp - 1
        ) else { return false }
        mutateRecord(at: \.domains.automations, id: id) { automation in
            automation.status = .ready
            automation.nextRunAtUnixMillis = next
            automation.lastResult = "Scheduled"
            if automation.authority == .standing {
                automation.standingAuthorityApprovedAtUnixMillis = timestamp
                automation.standingAuthorityApprovalID = approvalID
            }
        }
        return true
    }

    public func automationAuthorityTarget(for rule: DesktopAutomationRule) -> String? {
        struct Capability: Encodable {
            let id: String
            let name: String
            let kind: String
            let revision: String
            let source: String
            let scope: String
        }
        struct Contract: Encodable {
            let id: String
            let name: String
            let schedule: DesktopScheduleSpec
            let timeZoneIdentifier: String
            let actionSummary: String
            let missedRunPolicy: String
            let actionKind: String
            let authority: String
            let projectID: String?
            let workspacePath: String?
            let capabilities: [Capability]
            let notificationEnabled: Bool
        }
        guard let schedule = rule.scheduleSpec,
              let actionKind = rule.actionKind,
              let authority = rule.authority else { return nil }
        var selected: [Capability] = []
        for id in rule.skillIDs ?? [] {
            guard let skill = snapshot.domains.skills.first(where: { $0.id == id }) else { continue }
            selected.append(Capability(
                id: skill.id,
                name: skill.name,
                kind: skill.kind.rawValue,
                revision: skill.revision,
                source: skill.source,
                scope: skill.scope
            ))
        }
        selected.sort { $0.id < $1.id }
        guard selected.count == (rule.skillIDs ?? []).count else { return nil }
        let contract = Contract(
            id: rule.id,
            name: rule.name,
            schedule: schedule,
            timeZoneIdentifier: rule.timeZoneIdentifier,
            actionSummary: rule.actionSummary,
            missedRunPolicy: rule.missedRunPolicy.rawValue,
            actionKind: actionKind.rawValue,
            authority: authority.rawValue,
            projectID: rule.projectID,
            workspacePath: automationWorkspacePath(for: rule),
            capabilities: selected,
            notificationEnabled: rule.notificationEnabled ?? false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(contract) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "automation:\(rule.id):contract:sha256=\(digest)"
    }

    public func automationWorkspacePath(for rule: DesktopAutomationRule) -> String? {
        guard let projectID = rule.projectID else { return nil }
        if let path = snapshot.projects.first(where: { $0.id == projectID })?.path, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        }
        return snapshot.domains.gitWorkspaces.first(where: { $0.projectID == projectID && $0.status == .ready })
            .map { URL(fileURLWithPath: $0.localPath, isDirectory: true).standardizedFileURL.path }
    }

    public func isApprovalGranted(id: String, exactTarget: String, atUnixMillis timestamp: Int64? = nil) -> Bool {
        let checkedAt = timestamp ?? now()
        guard let approval = snapshot.operations.approvals.first(where: { $0.id == id }),
              approval.state == .approved,
              approval.exactTarget == exactTarget else { return false }
        return approval.expiresAtUnixMillis.map { $0 >= checkedAt } ?? true
    }

    /// Marks a successfully executed exact action as consumed. Consequential
    /// one-shot grants must not remain reusable merely because their target is
    /// still byte-for-byte identical after execution.
    @discardableResult
    public func consumeApproval(id: String, exactTarget: String) -> Bool {
        let timestamp = now()
        var consumed = false
        let persisted = mutate { snapshot in
            guard let index = snapshot.operations.approvals.firstIndex(where: { $0.id == id }),
                  snapshot.operations.approvals[index].state == .approved,
                  snapshot.operations.approvals[index].exactTarget == exactTarget,
                  snapshot.operations.approvals[index].expiresAtUnixMillis.map({ $0 >= timestamp }) ?? true else {
                return
            }
            snapshot.operations.approvals[index].state = .completed
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "approval",
                action: "consumed",
                target: exactTarget,
                state: .completed,
                detail: "The exact local approval was consumed after the action completed.",
                recordedAtUnixMillis: timestamp
            ))
            consumed = true
        }
        return persisted && consumed
    }

    public func exactEffectIsAuthorized(approvalID: String, target: String) -> Bool {
        !snapshot.preferences.safeMode && isApprovalGranted(id: approvalID, exactTarget: target)
    }

    public func setAutomationPaused(id: String, paused: Bool) {
        mutateRecord(at: \.domains.automations, id: id) { rule in
            rule.status = paused ? .paused : .draft
        }
    }

    public func updateAutomation(
        id: String,
        name: String,
        schedule: String,
        timeZoneIdentifier: String,
        actionSummary: String,
        missedRunPolicy: DesktopAutomationRule.MissedRunPolicy,
        scheduleSpec: DesktopScheduleSpec,
        actionKind: DesktopAutomationActionKind,
        authority: DesktopAutomationAuthority,
        projectID: String?,
        skillIDs: [String],
        notificationEnabled: Bool
    ) -> Bool {
        let fields = [name, schedule, actionSummary].map(Self.normalized)
        let selected = Array(Set(skillIDs)).sorted()
        guard fields.allSatisfy({ !$0.isEmpty }),
              TimeZone(identifier: timeZoneIdentifier) != nil,
              (actionKind == .notification || authority != .localOnly),
              (actionKind != .skill || !selected.isEmpty),
              selected.allSatisfy({ skillID in
                  snapshot.domains.skills.contains { $0.id == skillID && $0.enabled }
              }),
              snapshot.domains.automations.contains(where: { $0.id == id }),
              !snapshot.operations.automationRuns.contains(where: { $0.automationID == id && $0.state == .running }) else { return false }
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.domains.automations.firstIndex(where: { $0.id == id }) else { return }
            snapshot.domains.automations[index].name = fields[0]
            snapshot.domains.automations[index].schedule = fields[1]
            snapshot.domains.automations[index].timeZoneIdentifier = timeZoneIdentifier
            snapshot.domains.automations[index].actionSummary = fields[2]
            snapshot.domains.automations[index].missedRunPolicy = missedRunPolicy
            snapshot.domains.automations[index].scheduleSpec = scheduleSpec
            snapshot.domains.automations[index].actionKind = actionKind
            snapshot.domains.automations[index].authority = authority
            snapshot.domains.automations[index].projectID = projectID
            snapshot.domains.automations[index].skillIDs = selected
            snapshot.domains.automations[index].toolNames = []
            snapshot.domains.automations[index].notificationEnabled = notificationEnabled
            snapshot.domains.automations[index].status = .draft
            snapshot.domains.automations[index].nextRunAtUnixMillis = nil
            snapshot.domains.automations[index].lastResult = "Edited · review required"
            snapshot.domains.automations[index].standingAuthorityApprovedAtUnixMillis = nil
            snapshot.domains.automations[index].standingAuthorityApprovalID = nil
            for runIndex in snapshot.operations.automationRuns.indices
                where snapshot.operations.automationRuns[runIndex].automationID == id
                    && [.proposed, .awaitingApproval, .approved].contains(snapshot.operations.automationRuns[runIndex].state) {
                snapshot.operations.automationRuns[runIndex].state = .cancelled
                snapshot.operations.automationRuns[runIndex].completedAtUnixMillis = timestamp
                snapshot.operations.automationRuns[runIndex].detail = "The rule changed before this occurrence ran; review the edited contract."
            }
        }
        return true
    }

    public func deleteAutomation(id: String) -> Bool {
        guard snapshot.domains.automations.contains(where: { $0.id == id }),
              !snapshot.operations.automationRuns.contains(where: { $0.automationID == id && $0.state == .running }) else { return false }
        let timestamp = now()
        mutate { snapshot in
            snapshot.domains.automations.removeAll { $0.id == id }
            for index in snapshot.operations.automationRuns.indices
                where snapshot.operations.automationRuns[index].automationID == id
                    && ![DesktopActionState.completed, .failed, .cancelled, .interrupted].contains(snapshot.operations.automationRuns[index].state) {
                snapshot.operations.automationRuns[index].state = .cancelled
                snapshot.operations.automationRuns[index].completedAtUnixMillis = timestamp
                snapshot.operations.automationRuns[index].detail = "The automation was deleted before this occurrence completed."
            }
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "automation",
                action: "deleted",
                target: "automation:\(id)",
                state: .completed,
                detail: "Removed the local rule and cancelled its unfinished occurrences. Historical receipts remain available.",
                recordedAtUnixMillis: timestamp
            ))
        }
        return true
    }

    /// Adds a SKILL.md discovered on disk to the catalog so the Skills screen,
    /// composer picker, and search all see the same entry. `registryName` binds
    /// the catalog record to the on-disk skill used at run time.
    @discardableResult
    public func registerDiscoveredSkill(registryName: String, path: String, description: String) -> String? {
        let cleanName = Self.normalized(registryName)
        guard !cleanName.isEmpty else { return nil }
        if let existing = snapshot.domains.skills.first(where: { $0.registryName == cleanName }) { return existing.id }
        let record = DesktopSkillRecord(
            id: "skill-\(Self.stableLocalDigest(cleanName + "\u{0}" + path).prefix(16))",
            name: cleanName,
            registryName: cleanName,
            kind: .skill,
            scope: path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/.") ? "user" : "workspace",
            source: path,
            revision: Self.stableLocalDigest(description).prefix(12).description,
            status: .ready,
            enabled: true
        )
        let persisted = mutate { snapshot in
            snapshot.domains.skills.append(record)
        }
        return persisted ? record.id : nil
    }

    public func setSkillEnabled(id: String, enabled: Bool) {
        mutateRecord(at: \.domains.skills, id: id) { skill in
            skill.enabled = enabled
        }
    }

    @discardableResult
    public func addResearchSource(
        researchID: String,
        title: String,
        location: String,
        publisher: String,
        isPrimary: Bool,
        note: String
    ) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.domains.research.contains(where: { $0.id == researchID }),
              !cleanTitle.isEmpty, !cleanLocation.isEmpty,
              cleanTitle.utf8.count <= 300, cleanLocation.utf8.count <= 4_096 else { return nil }
        let source = DesktopResearchSource(
            id: UUID().uuidString.lowercased(),
            researchID: researchID,
            title: cleanTitle,
            location: cleanLocation,
            publisher: publisher.trimmingCharacters(in: .whitespacesAndNewlines),
            isPrimary: isPrimary,
            retrievedAtUnixMillis: now(),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        mutate { snapshot in
            snapshot.operations.researchSources.append(source)
            if let index = snapshot.domains.research.firstIndex(where: { $0.id == researchID }) {
                snapshot.domains.research[index].sourceCount += 1
                snapshot.domains.research[index].updatedAtUnixMillis = source.retrievedAtUnixMillis
            }
        }
        return source.id
    }

    public func codingKnowledgeLane(threadID: String) -> DesktopCodingKnowledgeLane? {
        snapshot.operations.codingKnowledgeLanes.first { $0.threadID == threadID }
    }

    public func codingWorkflow(threadID: String) -> DesktopCodingWorkflowRecord? {
        snapshot.operations.codingWorkflows.first { $0.threadID == threadID }
    }

    @discardableResult
    public func ensureCodingWorkflow(threadID: String) -> DesktopCodingWorkflowRecord? {
        guard let thread = thread(id: threadID), thread.kind == .coding else { return nil }
        if let existing = codingWorkflow(threadID: threadID) { return existing }
        let timestamp = now()
        guard mutate({ snapshot in
            Self.ensureCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                projectID: thread.projectID,
                timestamp: timestamp
            )
        }) else { return nil }
        return codingWorkflow(threadID: threadID)
    }

    @discardableResult
    public func updateCodingWorkflow(
        threadID: String,
        state: DesktopCodingWorkflowState,
        reason: String? = nil
    ) -> Bool {
        guard let thread = thread(id: threadID), thread.kind == .coding,
              let currentState = codingWorkflow(threadID: threadID)?.state,
              Self.allowsExternalCodingTransition(from: currentState, to: state) else { return false }
        let timestamp = now()
        return mutate { snapshot in
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                projectID: thread.projectID,
                state: state,
                reason: reason,
                timestamp: timestamp
            )
        }
    }

    @discardableResult
    public func replaceCodingKnowledgeContext(
        threadID: String,
        projectID: String? = nil,
        sources: [DesktopCodingKnowledgeConsultedSource]
    ) -> Bool {
        guard let thread = thread(id: threadID), thread.kind == .coding,
              sources.count <= Self.codingKnowledgeMaximumSourceCount else { return false }
        guard let boundedSources = Self.boundedCodingKnowledgeSources(sources) else { return false }
        let timestamp = now()
        return mutate { snapshot in
            let laneIndex: Int
            if let index = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }) {
                laneIndex = index
            } else {
                let lane = DesktopCodingKnowledgeLane(
                    projectID: projectID ?? thread.projectID,
                    threadID: threadID,
                    createdAtUnixMillis: timestamp,
                    updatedAtUnixMillis: timestamp
                )
                snapshot.operations.codingKnowledgeLanes.append(lane)
                laneIndex = snapshot.operations.codingKnowledgeLanes.count - 1
            }
            snapshot.operations.codingKnowledgeLanes[laneIndex].consultedSources = boundedSources
            snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            if snapshot.operations.codingKnowledgeLanes[laneIndex].projectID == nil {
                snapshot.operations.codingKnowledgeLanes[laneIndex].projectID = projectID ?? thread.projectID
            }
            Self.ensureCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                projectID: projectID ?? thread.projectID,
                timestamp: timestamp
            )
        }
    }

    @discardableResult
    public func addCodingKnowledgeCandidate(
        threadID: String,
        category: DesktopCodingKnowledgeCandidateCategory,
        title: String,
        detail: String,
        evidenceDigest: String? = nil
    ) -> String? {
        guard let thread = thread(id: threadID), thread.kind == .coding else { return nil }
        let cleanTitle = Self.normalized(title)
        let cleanDetail = Self.normalized(detail)
        let cleanEvidence = evidenceDigest.map(Self.normalized)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= Self.codingKnowledgeMaximumTitleBytes,
              !cleanDetail.isEmpty, cleanDetail.utf8.count <= Self.codingKnowledgeMaximumDetailBytes,
              cleanEvidence?.utf8.count ?? 0 <= Self.codingKnowledgeMaximumDigestBytes else { return nil }
        let timestamp = now()
        let candidate = DesktopCodingKnowledgeCandidate(
            category: category,
            title: cleanTitle,
            detail: cleanDetail,
            evidenceDigest: cleanEvidence
        )
        var result: String?
        let persisted = mutate { snapshot in
            let laneIndex: Int
            if let index = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }) {
                laneIndex = index
            } else {
                snapshot.operations.codingKnowledgeLanes.append(.init(
                    projectID: thread.projectID,
                    threadID: threadID,
                    createdAtUnixMillis: timestamp,
                    updatedAtUnixMillis: timestamp
                ))
                laneIndex = snapshot.operations.codingKnowledgeLanes.count - 1
            }
            let duplicate = snapshot.operations.codingKnowledgeLanes[laneIndex].candidates.contains {
                $0.category == category && $0.title == cleanTitle && $0.detail == cleanDetail
                    && $0.evidenceDigest == cleanEvidence
            }
            guard !duplicate,
                  snapshot.operations.codingKnowledgeLanes[laneIndex].candidates.count < Self.codingKnowledgeMaximumCandidateCount else { return }
            snapshot.operations.codingKnowledgeLanes[laneIndex].candidates.append(candidate)
            snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            Self.ensureCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                projectID: thread.projectID,
                timestamp: timestamp
            )
            result = candidate.id
        }
        return persisted ? result : nil
    }

    @discardableResult
    public func markCodingKnowledgeNeedsReview(threadID: String, reason: String) -> Bool {
        updateCodingKnowledgeDisposition(threadID: threadID, disposition: .needsReview, reason: reason)
    }

    @discardableResult
    public func linkCodingKnowledge(
        threadID: String,
        proposalID: String? = nil,
        writeID: String? = nil
    ) -> Bool {
        let cleanProposal = proposalID.map(Self.normalized)
        let cleanWrite = writeID.map(Self.normalized)
        guard cleanProposal?.isEmpty != true, cleanProposal?.utf8.count ?? 0 <= 256,
              cleanWrite?.isEmpty != true, cleanWrite?.utf8.count ?? 0 <= 256,
              thread(id: threadID)?.kind == .coding,
              codingWorkflow(threadID: threadID)?.state == .updatingKnowledge,
              Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
              codingKnowledgeLane(threadID: threadID) != nil,
              cleanProposal != nil || cleanWrite != nil else { return false }
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            guard let laneIndex = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }),
                  snapshot.threads.first(where: { $0.id == threadID })?.kind == .coding,
                  snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge,
                  Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID) else { return }
            snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID = cleanProposal ?? snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID
            snapshot.operations.codingKnowledgeLanes[laneIndex].writeID = cleanWrite ?? snapshot.operations.codingKnowledgeLanes[laneIndex].writeID
            snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .proposed
            snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "Knowledge update proposal is linked and awaiting review."
            snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .updatingKnowledge,
                reason: "Knowledge update proposal is linked and awaiting review.",
                timestamp: timestamp
            )
            didApply = true
        }
        return didApply && persisted
    }

    @discardableResult
    public func waiveCodingKnowledge(threadID: String, reason: String) -> Bool {
        guard let cleanReason = validatedCodingKnowledgeReason(threadID: threadID, reason: reason) else {
            return false
        }
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            guard let laneIndex = Self.codingKnowledgeLaneIndexForMutation(
                in: snapshot,
                threadID: threadID
            ) else { return }
            Self.setCodingKnowledgeLaneDisposition(
                in: &snapshot,
                laneIndex: laneIndex,
                disposition: .waived,
                reason: cleanReason,
                timestamp: timestamp
            )
            if let proposalID = snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID,
               let proposalIndex = snapshot.operations.knowledgeProposals.firstIndex(where: { $0.id == proposalID }),
               snapshot.operations.knowledgeProposals[proposalIndex].state != .reconciled {
                snapshot.operations.knowledgeProposals[proposalIndex].state = .cancelled
            }
            if let writeID = snapshot.operations.codingKnowledgeLanes[laneIndex].writeID,
               let writeIndex = snapshot.operations.knowledgeWrites.firstIndex(where: { $0.id == writeID }),
               snapshot.operations.knowledgeWrites[writeIndex].state != .reconciled {
                snapshot.operations.knowledgeWrites[writeIndex].state = .cancelled
                if let approvalID = snapshot.operations.knowledgeWrites[writeIndex].approvalID,
                   let approvalIndex = snapshot.operations.approvals.firstIndex(where: {
                       $0.id == approvalID && $0.state == .awaitingApproval
                   }) {
                    snapshot.operations.approvals[approvalIndex].state = .cancelled
                }
            }
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .completed,
                reason: "Knowledge update waived: \(cleanReason)",
                timestamp: timestamp
            )
            if let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
                snapshot.threads[threadIndex].attention = .completed
                snapshot.threads[threadIndex].summary = "Implementation accepted locally. Knowledge update waived: \(cleanReason)"
                snapshot.threads[threadIndex].unread = false
                snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
            }
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "knowledge",
                action: "coding knowledge waived",
                target: threadID,
                state: .completed,
                detail: cleanReason,
                recordedAtUnixMillis: timestamp
            ))
            didApply = true
        }
        return didApply && persisted
    }

    @discardableResult
    public func beginCodingKnowledgeRevision(threadID: String) -> Bool {
        guard thread(id: threadID)?.kind == .coding,
              codingWorkflow(threadID: threadID)?.state == .updatingKnowledge,
              Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
              let lane = codingKnowledgeLane(threadID: threadID),
              let writeID = lane.writeID,
              let write = snapshot.operations.knowledgeWrites.first(where: { $0.id == writeID }) else { return false }
        let approvalState = write.approvalID.flatMap { approvalID in
            snapshot.operations.approvals.first(where: { $0.id == approvalID })?.state
        }
        guard lane.disposition == .conflict || write.state == .failed
                || approvalState == .rejected || approvalState == .cancelled else { return false }
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            guard let laneIndex = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }),
                  snapshot.operations.codingKnowledgeLanes[laneIndex].writeID == writeID,
                  snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge,
                  Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID) else { return }
            snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID = nil
            snapshot.operations.codingKnowledgeLanes[laneIndex].writeID = nil
            snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .needsReview
            snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "The previous proposal was rejected or conflicted; inspect the current note and prepare a revised diff."
            snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .updatingKnowledge,
                reason: "A revised knowledge proposal is required from the current note revision.",
                timestamp: timestamp
            )
            didApply = true
        }
        return didApply && persisted
    }

    @discardableResult
    private func updateCodingKnowledgeDisposition(
        threadID: String,
        disposition: DesktopCodingKnowledgeDisposition,
        reason: String
    ) -> Bool {
        guard let cleanReason = validatedCodingKnowledgeReason(threadID: threadID, reason: reason) else {
            return false
        }
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            guard let laneIndex = Self.codingKnowledgeLaneIndexForMutation(
                in: snapshot,
                threadID: threadID
            ) else { return }
            Self.setCodingKnowledgeLaneDisposition(
                in: &snapshot,
                laneIndex: laneIndex,
                disposition: disposition,
                reason: cleanReason,
                timestamp: timestamp
            )
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .updatingKnowledge,
                reason: cleanReason,
                timestamp: timestamp
            )
            didApply = true
        }
        return didApply && persisted
    }

    private func validatedCodingKnowledgeReason(threadID: String, reason: String) -> String? {
        let cleanReason = Self.normalized(reason)
        guard thread(id: threadID)?.kind == .coding,
              codingWorkflow(threadID: threadID)?.state == .updatingKnowledge,
              Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
              codingKnowledgeLane(threadID: threadID) != nil,
              !cleanReason.isEmpty,
              cleanReason.utf8.count <= Self.codingKnowledgeMaximumReasonBytes else { return nil }
        return cleanReason
    }

    private static func codingKnowledgeLaneIndexForMutation(
        in snapshot: DesktopAppSnapshot,
        threadID: String
    ) -> Int? {
        guard snapshot.threads.first(where: { $0.id == threadID })?.kind == .coding,
              snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge,
              hasAcceptedCodingWorktree(in: snapshot, threadID: threadID) else { return nil }
        return snapshot.operations.codingKnowledgeLanes.firstIndex { $0.threadID == threadID }
    }

    private static func setCodingKnowledgeLaneDisposition(
        in snapshot: inout DesktopAppSnapshot,
        laneIndex: Int,
        disposition: DesktopCodingKnowledgeDisposition,
        reason: String,
        timestamp: Int64
    ) {
        snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = disposition
        snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = reason
        snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
    }

    @discardableResult
    public func createKnowledgeProposal(
        sourceID: String?,
        title: String,
        target: String,
        summary: String,
        proposedContent: String,
        baseRevision: String
    ) -> String? {
        let cleanTitle = Self.normalized(title)
        let cleanTarget = Self.normalized(target)
        let cleanSummary = Self.normalized(summary)
        let cleanBaseRevision = Self.normalized(baseRevision)
        let targetComponents = cleanTarget.split(separator: "/", omittingEmptySubsequences: false)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= 240,
              !cleanTarget.isEmpty, cleanTarget.utf8.count <= 2_048, !cleanTarget.hasPrefix("/"),
              !targetComponents.contains("."), !targetComponents.contains(".."), !targetComponents.contains(""),
              cleanSummary.utf8.count <= 16_384,
              !Self.normalized(proposedContent).isEmpty, proposedContent.utf8.count <= 2_097_152,
              !cleanBaseRevision.isEmpty, cleanBaseRevision.utf8.count <= 256 else { return nil }
        let proposal = DesktopKnowledgeProposal(
            id: UUID().uuidString.lowercased(),
            knowledgeSourceID: sourceID,
            title: cleanTitle,
            target: cleanTarget,
            summary: cleanSummary,
            proposedContent: proposedContent,
            baseRevision: cleanBaseRevision,
            state: .proposed,
            createdAtUnixMillis: now()
        )
        return mutate({ $0.operations.knowledgeProposals.append(proposal) }) ? proposal.id : nil
    }

    @discardableResult
    public func addVaultScope(path: String, sourceID: String?, canWrite: Bool) -> String? {
        let cleanPath = Self.normalized(path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = cleanPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !cleanPath.isEmpty, !cleanPath.hasPrefix("/"), cleanPath.utf8.count <= 2_048,
              !components.contains("."), !components.contains(".."), !components.contains("") else { return nil }
        if let existing = snapshot.operations.vaultScopes.first(where: { $0.path == cleanPath }) {
            mutate { value in
                guard let index = value.operations.vaultScopes.firstIndex(where: { $0.id == existing.id }) else { return }
                value.operations.vaultScopes[index].canRead = true
                value.operations.vaultScopes[index].canWrite = canWrite
                value.operations.vaultScopes[index].sourceID = sourceID
            }
            return existing.id
        }
        let scope = DesktopVaultScopeRecord(
            id: UUID().uuidString.lowercased(),
            sourceID: sourceID,
            path: cleanPath,
            canRead: true,
            canWrite: canWrite,
            lastReconciledAtUnixMillis: nil
        )
        mutate { $0.operations.vaultScopes.append(scope) }
        return scope.id
    }

    public func removeVaultScope(id: String) {
        mutate { $0.operations.vaultScopes.removeAll { $0.id == id } }
    }

    public func recordKnowledgeDocument(_ document: DesktopKnowledgeDocumentRecord) {
        mutate { snapshot in
            if let index = snapshot.operations.knowledgeDocuments.firstIndex(where: { $0.path == document.path }) {
                let existing = snapshot.operations.knowledgeDocuments[index]
                var reconciled = document
                reconciled.role = existing.role ?? document.role
                reconciled.projectID = existing.projectID ?? document.projectID
                snapshot.operations.knowledgeDocuments[index] = reconciled
            } else {
                snapshot.operations.knowledgeDocuments.append(document)
            }
            for index in snapshot.operations.vaultScopes.indices where
                document.path == snapshot.operations.vaultScopes[index].path
                    || document.path.hasPrefix(snapshot.operations.vaultScopes[index].path + "/") {
                snapshot.operations.vaultScopes[index].lastReconciledAtUnixMillis = document.lastReadAtUnixMillis
            }
        }
    }

    public func classifyKnowledgeDocument(
        path: String,
        projectID: String?,
        role: DesktopKnowledgeDocumentRecord.Role?
    ) {
        guard let id = snapshot.operations.knowledgeDocuments.first(where: { $0.path == path })?.id else { return }
        mutateRecord(at: \.operations.knowledgeDocuments, id: id) { document in
            document.projectID = projectID
            document.role = role
        }
    }

    @discardableResult
    public func recordKnowledgeWrite(
        proposalID: String,
        targetPath: String,
        baseDigest: String,
        proposedDigest: String,
        diffSummary: String,
        unifiedDiff: String
    ) -> String? {
        let cleanTargetPath = Self.normalized(targetPath)
        let cleanBaseDigest = Self.normalized(baseDigest)
        let cleanProposedDigest = Self.normalized(proposedDigest)
        guard let proposal = snapshot.operations.knowledgeProposals.first(where: {
            $0.id == proposalID && $0.state == .proposed
        }),
              proposal.target == cleanTargetPath,
              proposal.baseRevision == cleanBaseDigest,
              Self.stableLocalDigest(proposal.proposedContent) == cleanProposedDigest,
              !cleanTargetPath.isEmpty,
              !cleanBaseDigest.isEmpty,
              !cleanProposedDigest.isEmpty,
              diffSummary.utf8.count <= 16_384,
              unifiedDiff.utf8.count <= 524_288 else { return nil }
        let record = DesktopKnowledgeWriteRecord(
            id: UUID().uuidString.lowercased(),
            proposalID: proposalID,
            approvalID: nil,
            targetPath: cleanTargetPath,
            baseDigest: cleanBaseDigest,
            proposedDigest: cleanProposedDigest,
            diffSummary: diffSummary,
            unifiedDiff: unifiedDiff,
            state: .proposed,
            currentDigest: nil,
            createdAtUnixMillis: now(),
            reconciledAtUnixMillis: nil
        )
        let timestamp = now()
        let persisted = mutate { snapshot in
            snapshot.operations.knowledgeWrites.append(record)
            for laneIndex in snapshot.operations.codingKnowledgeLanes.indices
            where snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID == proposalID
                && Self.hasAcceptedCodingWorktree(
                    in: snapshot,
                    threadID: snapshot.operations.codingKnowledgeLanes[laneIndex].threadID
                ) {
                let threadID = snapshot.operations.codingKnowledgeLanes[laneIndex].threadID
                snapshot.operations.codingKnowledgeLanes[laneIndex].writeID = record.id
                snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .proposed
                snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "Knowledge write proposal is ready for review."
                snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
                Self.setCodingWorkflow(
                    in: &snapshot,
                    threadID: threadID,
                    state: .updatingKnowledge,
                    reason: "Knowledge write proposal is ready for review.",
                    timestamp: timestamp
                )
            }
        }
        return persisted ? record.id : nil
    }

    @discardableResult
    public func attachKnowledgeApproval(writeID: String, approvalID: String) -> Bool {
        guard let write = snapshot.operations.knowledgeWrites.first(where: { $0.id == writeID }),
              let approval = snapshot.operations.approvals.first(where: {
                  $0.id == approvalID && $0.state == .awaitingApproval
              }),
              approval.exactTarget == Self.knowledgeApprovalTarget(
                  path: write.targetPath,
                  baseDigest: write.baseDigest
              ) else { return false }
        if let lane = snapshot.operations.codingKnowledgeLanes.first(where: {
            $0.writeID == writeID || $0.proposalID == write.proposalID
        }), approval.threadID != lane.threadID { return false }
        var didApply = false
        let persisted = mutate { snapshot in
            guard let index = snapshot.operations.knowledgeWrites.firstIndex(where: { $0.id == writeID }),
                  let approval = snapshot.operations.approvals.first(where: {
                      $0.id == approvalID && $0.state == .awaitingApproval
                  }),
                  approval.exactTarget == Self.knowledgeApprovalTarget(
                      path: snapshot.operations.knowledgeWrites[index].targetPath,
                      baseDigest: snapshot.operations.knowledgeWrites[index].baseDigest
                  ) else { return }
            snapshot.operations.knowledgeWrites[index].approvalID = approvalID
            snapshot.operations.knowledgeWrites[index].state = .awaitingApproval
            let proposalID = snapshot.operations.knowledgeWrites[index].proposalID
            if let proposalIndex = snapshot.operations.knowledgeProposals.firstIndex(where: { $0.id == proposalID }) {
                snapshot.operations.knowledgeProposals[proposalIndex].state = .awaitingApproval
            }
            let timestamp = now()
            for laneIndex in snapshot.operations.codingKnowledgeLanes.indices
            where snapshot.operations.codingKnowledgeLanes[laneIndex].writeID == writeID
                || snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID == proposalID {
                let threadID = snapshot.operations.codingKnowledgeLanes[laneIndex].threadID
                guard Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
                      snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge else { continue }
                snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .awaitingApproval
                snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "Knowledge update is awaiting exact approval."
                snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
                Self.setCodingWorkflow(
                    in: &snapshot,
                    threadID: threadID,
                    state: .updatingKnowledge,
                    reason: "Knowledge update is awaiting exact approval.",
                    timestamp: timestamp
                )
            }
            didApply = true
        }
        return didApply && persisted
    }

    public func reconcileKnowledgeWrite(
        id: String,
        state: DesktopActionState,
        currentDigest: String?,
        detail: String
    ) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.knowledgeWrites.firstIndex(where: { $0.id == id }) else { return }
            let digestMatchesProposal = currentDigest != nil
                && currentDigest == snapshot.operations.knowledgeWrites[index].proposedDigest
            let effectiveState: DesktopActionState = state == .reconciled && !digestMatchesProposal ? .failed : state
            let effectiveDetail = state == .reconciled && !digestMatchesProposal
                ? "Reconciliation digest did not match the proposed content. \(detail)"
                : detail
            snapshot.operations.knowledgeWrites[index].state = effectiveState
            snapshot.operations.knowledgeWrites[index].currentDigest = currentDigest
            snapshot.operations.knowledgeWrites[index].reconciledAtUnixMillis = timestamp
            if let proposalIndex = snapshot.operations.knowledgeProposals.firstIndex(where: {
                $0.id == snapshot.operations.knowledgeWrites[index].proposalID
            }) { snapshot.operations.knowledgeProposals[proposalIndex].state = effectiveState }
            if let documentIndex = snapshot.operations.knowledgeDocuments.firstIndex(where: {
                $0.path == snapshot.operations.knowledgeWrites[index].targetPath
            }) { snapshot.operations.knowledgeDocuments[documentIndex].conflictDigest = effectiveState == .failed ? currentDigest : nil }
            let writeID = snapshot.operations.knowledgeWrites[index].id
            let proposalID = snapshot.operations.knowledgeWrites[index].proposalID
            let linkedLaneIndexes = snapshot.operations.codingKnowledgeLanes.indices.filter {
                snapshot.operations.codingKnowledgeLanes[$0].writeID == writeID
                    || snapshot.operations.codingKnowledgeLanes[$0].proposalID == proposalID
            }
            for laneIndex in linkedLaneIndexes {
                let threadID = snapshot.operations.codingKnowledgeLanes[laneIndex].threadID
                guard Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
                      snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge else { continue }
                if effectiveState == .reconciled {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .reconciled
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = KanameTextBounds.utf8Prefix(
                        Self.normalized(effectiveDetail),
                        maximumBytes: Self.codingKnowledgeMaximumReasonBytes
                    )
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID,
                        state: .completed,
                        reason: "Knowledge update reconciled successfully.",
                        timestamp: timestamp
                    )
                    if let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
                        snapshot.threads[threadIndex].attention = .completed
                        snapshot.threads[threadIndex].summary = "Implementation accepted locally. Knowledge update reconciled; nothing was pushed or published."
                        snapshot.threads[threadIndex].unread = false
                        snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
                    }
                } else if effectiveState == .failed {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .conflict
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = KanameTextBounds.utf8Prefix(
                        Self.normalized(effectiveDetail),
                        maximumBytes: Self.codingKnowledgeMaximumReasonBytes
                    )
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID,
                        state: .updatingKnowledge,
                        reason: "Knowledge update conflicted and requires review.",
                        timestamp: timestamp
                    )
                    if let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
                        snapshot.threads[threadIndex].attention = .needsApproval
                        snapshot.threads[threadIndex].summary = "Knowledge update conflicted; review the external note and decide whether to retry or waive it."
                        snapshot.threads[threadIndex].unread = true
                        snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
                    }
                }
                snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            }
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "knowledge",
                action: "write reconciliation",
                target: snapshot.operations.knowledgeWrites[index].targetPath,
                state: effectiveState,
                detail: effectiveDetail,
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    public func reviewCapabilityUpdate(id: String, accepted: Bool) {
        mutate { snapshot in
            snapshot.operations.capabilityUpdates = snapshot.operations.capabilityUpdates.map { update in
                guard update.id == id else { return update }
                var reviewed = update
                reviewed.state = accepted ? .approved : .rejected
                reviewed.reviewedAtUnixMillis = now()
                return reviewed
            }
        }
    }

    @discardableResult
    public func createApproval(
        threadID: String?,
        title: String,
        exactTarget: String,
        consequence: String,
        dataLeavingDevice: String,
        reversible: Bool,
        expiresAtUnixMillis: Int64?
    ) -> String? {
        let required = (
            title: Self.normalized(title),
            target: Self.normalized(exactTarget),
            consequence: Self.normalized(consequence)
        )
        guard !required.title.isEmpty, !required.target.isEmpty, !required.consequence.isEmpty else { return nil }
        let approval = DesktopApprovalRecord(
            id: UUID().uuidString.lowercased(),
            threadID: threadID,
            title: required.title,
            exactTarget: required.target,
            consequence: required.consequence,
            dataLeavingDevice: Self.normalized(dataLeavingDevice),
            reversible: reversible,
            state: .awaitingApproval,
            requestedAtUnixMillis: now(),
            expiresAtUnixMillis: expiresAtUnixMillis
        )
        mutate { snapshot in
            snapshot.operations.approvals.append(approval)
            snapshot.operations.audit.append(
                DesktopAuditRecord(
                    id: UUID().uuidString.lowercased(),
                    domain: "approval",
                    action: "requested",
                    target: approval.exactTarget,
                    state: .awaitingApproval,
                    detail: approval.consequence,
                    recordedAtUnixMillis: approval.requestedAtUnixMillis
                )
            )
        }
        return approval.id
    }

    public func resolveApproval(id: String, approved: Bool) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.approvals.firstIndex(where: { $0.id == id }),
                  snapshot.operations.approvals[index].state == .awaitingApproval else { return }
            if snapshot.operations.approvals[index].expiresAtUnixMillis.map({ $0 < timestamp }) ?? false {
                snapshot.operations.approvals[index].state = .cancelled
                Self.applyKnowledgeApprovalDecision(
                    in: &snapshot,
                    approvalID: id,
                    state: .cancelled,
                    timestamp: timestamp
                )
                snapshot.operations.audit.append(DesktopAuditRecord(
                    id: UUID().uuidString.lowercased(),
                    domain: "approval",
                    action: "expired",
                    target: snapshot.operations.approvals[index].exactTarget,
                    state: .cancelled,
                    detail: "The approval expired before a decision; no action was dispatched.",
                    recordedAtUnixMillis: timestamp
                ))
                return
            }
            let state: DesktopActionState = approved ? .approved : .rejected
            snapshot.operations.approvals[index].state = state
            Self.applyKnowledgeApprovalDecision(
                in: &snapshot,
                approvalID: id,
                state: state,
                timestamp: timestamp
            )
            snapshot.operations.audit.append(
                DesktopAuditRecord(
                    id: UUID().uuidString.lowercased(),
                    domain: "approval",
                    action: approved ? "approved" : "rejected",
                    target: snapshot.operations.approvals[index].exactTarget,
                    state: state,
                    detail: "Local approval decision recorded; no external action was dispatched.",
                    recordedAtUnixMillis: timestamp
                )
            )
        }
    }

    @discardableResult
    public func createProviderComparison(title: String, brief: String, providers: [String]) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBrief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let uniqueProviders = Array(Set(providers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
            .sorted()
        guard !cleanTitle.isEmpty, !cleanBrief.isEmpty, uniqueProviders.count >= 2 else { return nil }
        let timestamp = now()
        let runs = uniqueProviders.map { provider in
            DesktopProviderRunRecord(
                id: UUID().uuidString.lowercased(),
                threadID: nil,
                turnID: UUID().uuidString.lowercased(),
                provider: provider,
                model: "Not selected",
                briefDigest: Self.stableLocalDigest(cleanBrief),
                contextReferenceCount: 0,
                tokenUsage: nil,
                costSummary: "Not run",
                state: .proposed,
                startedAtUnixMillis: timestamp,
                completedAtUnixMillis: nil
            )
        }
        let comparison = DesktopComparisonRecord(
            id: UUID().uuidString.lowercased(),
            title: cleanTitle,
            brief: cleanBrief,
            runIDs: runs.map(\.id),
            state: .proposed,
            createdAtUnixMillis: timestamp
        )
        let decision = DesktopComparisonDecisionRecord(
            id: "decision-\(comparison.id)",
            comparisonID: comparison.id,
            frozenContextDigest: Self.stableLocalDigest(cleanBrief),
            selectedRunID: nil,
            continuedThreadID: nil,
            decidedAtUnixMillis: nil
        )
        mutate { snapshot in
            snapshot.operations.providerRuns.append(contentsOf: runs)
            snapshot.operations.comparisons.append(comparison)
            snapshot.operations.comparisonDecisions.append(decision)
        }
        return comparison.id
    }

    public func prepareProviderComparison(id: String, projectID: String?) -> [String] {
        guard let comparisonIndex = snapshot.operations.comparisons.firstIndex(where: {
            $0.id == id && $0.state == .proposed
        }) else { return [] }
        let comparison = snapshot.operations.comparisons[comparisonIndex]
        let timestamp = now()
        var preparedRunIDs: [String] = []
        mutate { snapshot in
            for runID in comparison.runIDs {
                guard let runIndex = snapshot.operations.providerRuns.firstIndex(where: {
                    $0.id == runID && $0.threadID == nil
                }) else { continue }
                let provider = snapshot.operations.providerRuns[runIndex].provider
                let turnID = snapshot.operations.providerRuns[runIndex].turnID
                let threadID = UUID().uuidString.lowercased()
                let messageID = turnID
                let thread = DesktopThread(
                    id: threadID,
                    projectID: projectID,
                    title: "\(comparison.title) · \(provider)",
                    summary: "Frozen equal-context comparison run",
                    kind: .coding,
                    attention: .queued,
                    provider: provider,
                    model: "Use provider default",
                    updatedAtUnixMillis: timestamp,
                    messages: [DesktopMessage(
                        id: messageID,
                        turnID: turnID,
                        role: .user,
                        body: comparison.brief,
                        createdAtUnixMillis: timestamp
                    )]
                )
                snapshot.threads.append(thread)
                snapshot.operations.providerRuns[runIndex].threadID = threadID
                snapshot.operations.providerRuns[runIndex].sourceMessageID = messageID
                snapshot.operations.providerRuns[runIndex].model = "Use provider default"
                snapshot.operations.providerRuns[runIndex].costSummary = "Queued from frozen context"
                preparedRunIDs.append(runID)
            }
            snapshot.operations.comparisons[comparisonIndex].state = preparedRunIDs.isEmpty ? .failed : .running
        }
        return preparedRunIDs
    }

    public func selectProviderComparisonResult(comparisonID: String, runID: String) -> String? {
        guard let comparison = snapshot.operations.comparisons.first(where: { $0.id == comparisonID }),
              comparison.runIDs.contains(runID),
              let run = snapshot.operations.providerRuns.first(where: { $0.id == runID && $0.state == .completed }),
              let threadID = run.threadID else { return nil }
        let timestamp = now()
        mutate { snapshot in
            if let index = snapshot.operations.comparisons.firstIndex(where: { $0.id == comparisonID }) {
                snapshot.operations.comparisons[index].state = .completed
            }
            if let index = snapshot.operations.comparisonDecisions.firstIndex(where: { $0.comparisonID == comparisonID }) {
                snapshot.operations.comparisonDecisions[index].selectedRunID = runID
                snapshot.operations.comparisonDecisions[index].continuedThreadID = threadID
                snapshot.operations.comparisonDecisions[index].decidedAtUnixMillis = timestamp
            }
        }
        return threadID
    }

    @discardableResult
    public func proposeWorktree(
        projectID: String,
        threadID: String,
        rootWorkspacePath: String,
        worktreePath: String,
        branch: String,
        baseRevision: String
    ) -> String? {
        let root = Self.normalized(rootWorkspacePath)
        let target = Self.normalized(worktreePath)
        let cleanBranch = Self.normalized(branch)
        let cleanBase = Self.normalized(baseRevision)
        guard snapshot.projects.contains(where: { $0.id == projectID }),
              snapshot.threads.contains(where: { $0.id == threadID && $0.projectID == projectID }),
              !root.isEmpty, !target.isEmpty, !cleanBranch.isEmpty, !cleanBase.isEmpty else { return nil }
        let timestamp = now()
        let record = DesktopWorktreeRecord(
            id: UUID().uuidString.lowercased(),
            projectID: projectID,
            threadID: threadID,
            rootWorkspacePath: root,
            worktreePath: target,
            branch: cleanBranch,
            baseRevision: cleanBase,
            headRevision: nil,
            changedFileCount: 0,
            diffSummary: "Not created",
            testCommand: "",
            testSummary: "Not run",
            diagnosticSummary: "Not inspected",
            state: .proposed,
            createdAtUnixMillis: timestamp,
            updatedAtUnixMillis: timestamp
        )
        mutate { $0.operations.worktrees.append(record) }
        return record.id
    }

    public func updateWorktree(
        id: String,
        headRevision: String?,
        changedFileCount: Int,
        diffSummary: String,
        testCommand: String? = nil,
        testSummary: String? = nil,
        diagnosticSummary: String? = nil,
        state: DesktopWorktreeState
    ) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.worktrees.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.worktrees[index].headRevision = headRevision
            snapshot.operations.worktrees[index].changedFileCount = max(0, changedFileCount)
            snapshot.operations.worktrees[index].diffSummary = String(diffSummary.prefix(32_000))
            if let testCommand { snapshot.operations.worktrees[index].testCommand = String(testCommand.prefix(4_096)) }
            if let testSummary { snapshot.operations.worktrees[index].testSummary = String(testSummary.prefix(32_000)) }
            if let diagnosticSummary { snapshot.operations.worktrees[index].diagnosticSummary = String(diagnosticSummary.prefix(32_000)) }
            snapshot.operations.worktrees[index].state = state
            snapshot.operations.worktrees[index].updatedAtUnixMillis = timestamp
        }
    }

    public func upsertCodingTerminal(_ record: DesktopCodingTerminalRecord) {
        mutate { snapshot in
            Self.replaceOrAppend(
                record,
                in: &snapshot.operations.codingTerminals
            ) { $0.id == record.id && $0.threadID == record.threadID }
        }
    }

    public func upsertCodingCheckpoint(_ record: DesktopCodingCheckpointRecord) {
        mutate { snapshot in
            Self.replaceOrAppend(record, in: &snapshot.operations.codingCheckpoints) { $0.id == record.id }
        }
    }

    public func upsertCodingPreviewTab(_ record: DesktopCodingPreviewTabRecord) {
        mutate { snapshot in
            Self.replaceOrAppend(record, in: &snapshot.operations.codingPreviewTabs) { $0.id == record.id }
        }
    }

    private static func replaceOrAppend<Element>(
        _ element: Element,
        in elements: inout [Element],
        matching: (Element) -> Bool
    ) {
        if let index = elements.firstIndex(where: matching) {
            elements[index] = element
        } else {
            elements.append(element)
        }
    }

    @discardableResult
    public func recordQualityGate(
        threadID: String,
        worktreeID: String?,
        kind: DesktopQualityGateKind,
        command: String,
        summary: String,
        state: DesktopActionState,
        artifactIDs: [String] = []
    ) -> String? {
        guard snapshot.threads.contains(where: { $0.id == threadID }),
              worktreeID == nil || snapshot.operations.worktrees.contains(where: { $0.id == worktreeID }) else { return nil }
        let record = DesktopQualityGateRecord(
            id: UUID().uuidString.lowercased(),
            threadID: threadID,
            worktreeID: worktreeID,
            kind: kind,
            command: String(Self.normalized(command).prefix(4_096)),
            summary: String(Self.normalized(summary).prefix(32_000)),
            state: state,
            artifactIDs: artifactIDs,
            recordedAtUnixMillis: now()
        )
        mutate { snapshot in
            snapshot.operations.qualityGates.removeAll {
                $0.threadID == threadID && $0.worktreeID == worktreeID && $0.kind == kind
            }
            snapshot.operations.qualityGates.append(record)
        }
        return record.id
    }

    public func recordSubagentActivity(
        threadID: String,
        runID: String,
        provider: String,
        nativeID: String,
        parentNativeID: String? = nil,
        title: String,
        detail: String,
        state: DesktopSubagentState
    ) {
        let id = "subagent-\(Self.stableLocalDigest("\(runID)|\(nativeID)"))"
        let parentID = parentNativeID.map {
            "subagent-\(Self.stableLocalDigest("\(runID)|\($0)"))"
        }
        let timestamp = now()
        mutate { snapshot in
            if let index = snapshot.operations.subagents.firstIndex(where: { $0.id == id }) {
                snapshot.operations.subagents[index].parentID = parentID
                snapshot.operations.subagents[index].title = String(Self.normalized(title).prefix(240))
                snapshot.operations.subagents[index].detail = String(detail.prefix(8_192))
                snapshot.operations.subagents[index].state = state
                snapshot.operations.subagents[index].completedAtUnixMillis = [.completed, .failed, .interrupted].contains(state) ? timestamp : nil
            } else {
                snapshot.operations.subagents.append(DesktopSubagentRecord(
                    id: id,
                    threadID: threadID,
                    runID: runID,
                    parentID: parentID,
                    provider: provider,
                    title: String(Self.normalized(title).prefix(240)),
                    detail: String(detail.prefix(8_192)),
                    state: state,
                    startedAtUnixMillis: timestamp,
                    completedAtUnixMillis: [.completed, .failed, .interrupted].contains(state) ? timestamp : nil
                ))
            }
        }
    }

    public func replacePullRequests(workspaceID: String, records: [DesktopPullRequestReconciliation]) {
        mutate { snapshot in
            snapshot.operations.pullRequests.removeAll { $0.workspaceID == workspaceID }
            snapshot.operations.pullRequests.append(contentsOf: records.map { record in
                DesktopPullRequestRecord(
                    id: "\(record.repository)#\(record.number)",
                    workspaceID: workspaceID,
                    repository: record.repository,
                    number: record.number,
                    title: record.title,
                    url: record.url,
                    headBranch: record.headBranch,
                    baseBranch: record.baseBranch,
                    checkSummary: record.checkSummary,
                    reviewSummary: record.reviewSummary,
                    mergeAfterIDs: record.mergeAfterIDs,
                    state: record.state,
                    lastReconciledAtUnixMillis: record.reconciledAtUnixMillis
                )
            })
        }
    }

    @discardableResult
    public func addGitStackLayer(
        workspaceID: String,
        title: String,
        branch: String,
        baseBranch: String,
        dependsOnLayerID: String?
    ) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBase = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.domains.gitWorkspaces.contains(where: { $0.id == workspaceID }),
              !cleanTitle.isEmpty, !cleanBranch.isEmpty, !cleanBase.isEmpty else { return nil }
        if let dependsOnLayerID,
           !snapshot.operations.gitStackLayers.contains(where: { $0.id == dependsOnLayerID }) {
            return nil
        }
        let layer = DesktopGitStackLayer(
            id: UUID().uuidString.lowercased(),
            workspaceID: workspaceID,
            title: cleanTitle,
            branch: cleanBranch,
            baseBranch: cleanBase,
            pullRequestURL: nil,
            checkSummary: "Not checked",
            reviewSummary: "No remote review",
            state: .proposed,
            dependsOnLayerID: dependsOnLayerID
        )
        mutate { $0.operations.gitStackLayers.append(layer) }
        return layer.id
    }

    public func updateGitStackLayer(
        id: String,
        pullRequestURL: String?,
        checkSummary: String,
        reviewSummary: String,
        state: DesktopActionState
    ) {
        mutate { snapshot in
            guard let index = snapshot.operations.gitStackLayers.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.gitStackLayers[index].pullRequestURL = pullRequestURL
            snapshot.operations.gitStackLayers[index].checkSummary = String(checkSummary.prefix(4_096))
            snapshot.operations.gitStackLayers[index].reviewSummary = String(reviewSummary.prefix(4_096))
            snapshot.operations.gitStackLayers[index].state = state
        }
    }

    @discardableResult
    public func registerArtifact(
        threadID: String?,
        name: String,
        kind: DesktopArtifactRecord.Kind,
        localPath: String,
        digest: String,
        provenance: String
    ) -> String? {
        let identity = (name: Self.normalized(name), path: Self.normalized(localPath))
        guard !identity.name.isEmpty, !identity.path.isEmpty else { return nil }
        switch threadID {
        case .some(let value) where !snapshot.threads.contains(where: { $0.id == value }):
            return nil
        default:
            break
        }
        let artifact = DesktopArtifactRecord(
            id: UUID().uuidString.lowercased(),
            threadID: threadID,
            name: identity.name,
            kind: kind,
            localPath: identity.path,
            digest: Self.normalized(digest),
            provenance: Self.normalized(provenance),
            createdAtUnixMillis: now()
        )
        mutate { $0.operations.artifacts.append(artifact) }
        return artifact.id
    }

    @discardableResult
    public func recordAutomationDryRun(id: String) -> String? {
        guard snapshot.domains.automations.contains(where: { $0.id == id }) else { return nil }
        let timestamp = now()
        let run = DesktopAutomationRunRecord(
            id: UUID().uuidString.lowercased(),
            automationID: id,
            scheduledAtUnixMillis: timestamp,
            startedAtUnixMillis: timestamp,
            completedAtUnixMillis: timestamp,
            state: .completed,
            detail: "Dry run validated local schedule metadata. No tools, accounts, providers, or external effects were invoked.",
            evidenceArtifactIDs: []
        )
        let persisted = mutate { snapshot in
            snapshot.operations.automationRuns.append(run)
            snapshot.domains.automations = snapshot.domains.automations.map { automation in
                var updated = automation
                if updated.id == id { updated.lastResult = "Dry run passed" }
                return updated
            }
        }
        return persisted ? run.id : nil
    }

    public func dueAutomationIDs(atUnixMillis timestamp: Int64) -> [String] {
        snapshot.domains.automations.filter {
            $0.status == .ready && ($0.nextRunAtUnixMillis ?? Int64.max) <= timestamp
        }.sorted {
            ($0.nextRunAtUnixMillis ?? Int64.max) < ($1.nextRunAtUnixMillis ?? Int64.max)
        }.map(\.id)
    }

    @discardableResult
    public func claimAutomationRun(id: String, ownerID: String, nowUnixMillis timestamp: Int64) -> String? {
        guard let rule = snapshot.domains.automations.first(where: { $0.id == id && $0.status == .ready }),
              let scheduled = rule.nextRunAtUnixMillis,
              scheduled <= timestamp,
              let spec = rule.scheduleSpec else { return nil }
        guard (rule.skillIDs ?? []).allSatisfy({ skillID in
            snapshot.domains.skills.contains { $0.id == skillID && $0.enabled }
        }) else {
            mutateRecord(at: \.domains.automations, id: id) {
                $0.status = .paused
                $0.lastResult = "Paused · selected capability unavailable"
            }
            return nil
        }
        let key = DesktopScheduleEngine.deduplicationKey(automationID: id, scheduledAtUnixMillis: scheduled)
        guard !snapshot.operations.automationRuns.contains(where: { $0.deduplicationKey == key }) else {
            advanceAutomation(id: id, spec: spec, after: scheduled)
            return nil
        }
        guard let contractTarget = automationAuthorityTarget(for: rule) else { return nil }
        let exactTarget = "\(contractTarget):occurrence=\(scheduled)"
        let missed = timestamp - scheduled > 120_000
        let state: DesktopActionState
        let detail: String
        if missed, rule.missedRunPolicy == .skip {
            state = .completed
            detail = "Skipped a missed occurrence by policy; no action ran."
        } else if rule.authority == .askEveryRun
                    || (missed && rule.missedRunPolicy == .ask)
                    || (rule.authority == .standing && !(rule.standingAuthorityApprovalID.map {
                        isApprovalGranted(id: $0, exactTarget: contractTarget, atUnixMillis: timestamp)
                    } ?? false)) {
            state = .awaitingApproval
            detail = missed ? "A missed occurrence needs catch-up approval." : "This occurrence needs exact run approval."
        } else {
            state = .approved
            detail = "Claimed by the single desktop scheduler owner and ready to execute."
        }
        var run = DesktopAutomationRunRecord(
            id: UUID().uuidString.lowercased(),
            automationID: id,
            scheduledAtUnixMillis: scheduled,
            startedAtUnixMillis: state == .approved ? timestamp : nil,
            completedAtUnixMillis: state == .completed ? timestamp : nil,
            state: state,
            detail: detail,
            evidenceArtifactIDs: []
        )
        run.deduplicationKey = key
        run.ownerID = ownerID
        run.wasMissed = missed
        run.contractTarget = contractTarget
        run.exactTarget = exactTarget
        run.workspacePath = automationWorkspacePath(for: rule)
        let next = try? DesktopScheduleEngine.nextOccurrence(
            spec: spec,
            timeZoneIdentifier: rule.timeZoneIdentifier,
            after: missed ? timestamp : scheduled
        )
        let persisted = mutate { snapshot in
            snapshot.operations.automationRuns.append(run)
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "automation",
                action: state == .completed ? "missed-skip" : "claimed",
                target: key,
                state: state,
                detail: detail,
                recordedAtUnixMillis: timestamp
            ))
            guard let index = snapshot.domains.automations.firstIndex(where: { $0.id == id }) else { return }
            snapshot.domains.automations[index].nextRunAtUnixMillis = next ?? nil
            if next == nil { snapshot.domains.automations[index].status = .paused }
        }
        return persisted ? run.id : nil
    }

    public func attachAutomationApproval(runID: String, approvalID: String) {
        mutateRecord(at: \.operations.automationRuns, id: runID) { run in
            run.approvalID = approvalID
        }
    }

    public func automationRun(id: String) -> DesktopAutomationRunRecord? {
        snapshot.operations.automationRuns.first { $0.id == id }
    }

    public func automationRunContractIsCurrent(id: String) -> Bool {
        guard let run = automationRun(id: id),
              let rule = snapshot.domains.automations.first(where: { $0.id == run.automationID }),
              automationAuthorityTarget(for: rule) == run.contractTarget,
              automationWorkspacePath(for: rule) == run.workspacePath else { return false }
        return true
    }

    @discardableResult
    public func attachAutomationDispatch(runID: String, threadID: String, providerRunID: String) -> Bool {
        mutateRecord(at: \.operations.automationRuns, id: runID) { run in
            run.threadID = threadID
            run.providerRunID = providerRunID
            run.detail = "Dispatched one durable read-only provider run; Kaname is tracking its terminal result."
        }
    }

    public func updateAutomationNotificationState(runID: String, state: String) {
        mutateRecord(at: \.operations.automationRuns, id: runID) { $0.notificationState = String(state.prefix(160)) }
    }

    public func beginApprovedAutomationRun(id: String) -> DesktopAutomationRunRecord? {
        guard let run = automationRun(id: id), run.state == .approved || run.state == .awaitingApproval else { return nil }
        if run.state == .awaitingApproval {
            guard let approvalID = run.approvalID,
                  let exactTarget = run.exactTarget,
                  isApprovalGranted(id: approvalID, exactTarget: exactTarget) else { return nil }
        }
        let timestamp = now()
        guard mutateRecord(at: \.operations.automationRuns, id: id, change: { value in
            value.state = .running
            value.startedAtUnixMillis = timestamp
            value.detail = "Executing the resolved automation contract."
        }) else { return nil }
        return automationRun(id: id)
    }

    public func completeAutomationRun(
        id: String,
        state: DesktopActionState,
        detail: String,
        threadID: String? = nil,
        notificationState: String? = nil
    ) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.automationRuns.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.automationRuns[index].state = state
            snapshot.operations.automationRuns[index].detail = String(detail.prefix(8_192))
            snapshot.operations.automationRuns[index].completedAtUnixMillis = timestamp
            snapshot.operations.automationRuns[index].threadID = threadID
            snapshot.operations.automationRuns[index].notificationState = notificationState
            if let ruleIndex = snapshot.domains.automations.firstIndex(where: {
                $0.id == snapshot.operations.automationRuns[index].automationID
            }) {
                snapshot.domains.automations[ruleIndex].lastResult = state == .completed ? "Completed" : "Failed"
            }
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "automation",
                action: "execute",
                target: snapshot.operations.automationRuns[index].deduplicationKey ?? id,
                state: state,
                detail: String(detail.prefix(8_192)),
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    private func advanceAutomation(id: String, spec: DesktopScheduleSpec, after scheduled: Int64) {
        let next = try? DesktopScheduleEngine.nextOccurrence(
            spec: spec,
            timeZoneIdentifier: snapshot.domains.automations.first(where: { $0.id == id })?.timeZoneIdentifier ?? "UTC",
            after: scheduled
        )
        mutateRecord(at: \.domains.automations, id: id) { automation in
            automation.nextRunAtUnixMillis = next ?? nil
            if next == nil { automation.status = .paused }
        }
    }

    public func clearPersistenceError() {
        guard recoveryStatus == nil else { return }
        persistenceError = nil
    }

    @discardableResult
    public func exportRecoveryBackup(to destination: URL) throws -> DesktopBackupManifest {
        guard flushComposerDrafts() else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
        guard let fileStore = store as? FileDesktopStateStore else {
            throw DesktopModelRecoveryError.recoveryUnavailable
        }
        return try fileStore.exportRecoveryBackup(
            to: destination,
            stateSchemaVersion: recoveryStatus?.detectedStateSchemaVersion ?? snapshot.version,
            createdAtUnixMillis: now()
        )
    }

    public func workflowInstallationStorageURL(workflowID: String) -> URL? {
        guard workflowID.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil,
              let fileStore = store as? FileDesktopStateStore else { return nil }
        return fileStore.applicationSupportRootURL
            .appendingPathComponent("WorkflowInstallations", isDirectory: true)
            .appendingPathComponent(workflowID, isDirectory: true)
    }

    public func workflowCapabilityStore() -> DesktopWorkflowCapabilityStore? {
        guard let fileStore = store as? FileDesktopStateStore else { return nil }
        return DesktopWorkflowCapabilityStore(rootDirectory: fileStore.workflowCapabilitiesDirectoryURL)
    }

    public func restorePreviousWorkspace() throws {
        guard recoveryStatus != nil else { throw DesktopModelRecoveryError.recoveryNotRequired }
        guard recoveryStatus?.reason != .runtimeRollbackUnverified else {
            throw DesktopModelRecoveryError.restoreArtifactInvalid
        }
        var runtimeLock: KanameRuntimeRecoveryFileLock?
        if let fileStore = store as? FileDesktopStateStore {
            runtimeLock = try fileStore.acquireExclusiveRuntimeRecoveryLock()
            try fileStore.requireRuntimeQuiescent()
            guard try !fileStore.hasRuntimeState() else {
                throw DesktopModelRecoveryError.restoreArtifactInvalid
            }
        }
        defer { _ = runtimeLock }
        guard let recoveryStore = store as? any DesktopRecoveryStateStoring,
              let recoveryData = try recoveryStore.loadRecovery() else {
            throw DesktopModelRecoveryError.previousWorkspaceUnavailable
        }
        var receipt: DesktopRestoreReceipt?
        if let fileStore = store as? FileDesktopStateStore,
           let backup = try fileStore.createPrivateBackupHistory(
               stateSchemaVersion: recoveryStatus?.detectedStateSchemaVersion ?? snapshot.version,
               createdAtUnixMillis: now()
           ) {
            let matches = backup.artifacts.filter { $0.kind == .previousWorkspaceState }
            guard matches.count == 1, let artifact = matches.first,
                  artifact.byteCount == Int64(recoveryData.count),
                  artifact.sha256 == DesktopRecoveryService.sha256(recoveryData) else {
                throw DesktopModelRecoveryError.restoreArtifactInvalid
            }
            receipt = DesktopRestoreReceipt(
                restoreID: UUID(),
                backupID: backup.backupID,
                stagedAtUnixMillis: now(),
                verifiedArtifactCount: 1,
                verifiedByteCount: Int64(recoveryData.count)
            )
        }
        try restoreVerifiedWorkspaceData(recoveryData, receipt: receipt)
    }

    public func restoreWorkspace(
        fromVerifiedBackup bundleURL: URL,
        artifactKind: DesktopRecoveryArtifactKind = .workspaceState
    ) throws {
        guard recoveryStatus != nil else { throw DesktopModelRecoveryError.recoveryNotRequired }
        guard artifactKind == .workspaceState || artifactKind == .previousWorkspaceState else {
            throw DesktopModelRecoveryError.restoreArtifactInvalid
        }
        let service = DesktopRecoveryService()
        let manifest = try service.validateBackup(at: bundleURL)
        if recoveryStatus?.reason == .runtimeRollbackUnverified,
           manifest.runtimeStateIncluded != true {
            throw DesktopModelRecoveryError.restoreArtifactInvalid
        }
        let data = try service.verifiedArtifactData(kind: artifactKind, from: bundleURL)
        let artifact = try Self.requireSingleRecoveryArtifact(kind: artifactKind, in: manifest)
        let restoreID = UUID()
        var runtimeTransaction: DesktopRuntimeRestoreTransaction?
        var originalWorkspaceData: Data?
        var runtimeLock: KanameRuntimeRecoveryFileLock?
        if let fileStore = store as? FileDesktopStateStore {
            runtimeLock = try fileStore.acquireExclusiveRuntimeRecoveryLock()
            try fileStore.requireRuntimeQuiescent()
            originalWorkspaceData = try fileStore.load()
            _ = try fileStore.createPrivateBackupHistory(
                stateSchemaVersion: recoveryStatus?.detectedStateSchemaVersion ?? snapshot.version,
                createdAtUnixMillis: now(),
                includesRuntimeState: true
            )
            do {
                runtimeTransaction = try fileStore.activateVerifiedRuntimeRestore(
                    from: bundleURL,
                    restoreID: restoreID
                )
            } catch {
                if let recoveryError = error as? DesktopModelRecoveryError,
                   recoveryError == .recoveryRollbackFailed {
                    try forceRecoveryReadOnlyAfterRollbackFailure(
                        fileStore: fileStore,
                        code: "restore-runtime-activation-rollback-unverified"
                    )
                }
                throw error
            }
        }
        defer { _ = runtimeLock }
        let receipt = DesktopRestoreReceipt(
            restoreID: restoreID,
            backupID: manifest.backupID,
            stagedAtUnixMillis: now(),
            verifiedArtifactCount: manifest.runtimeStateIncluded == true ? manifest.artifacts.count : 1,
            verifiedByteCount: manifest.runtimeStateIncluded == true
                ? manifest.artifacts.reduce(0) { $0 + $1.byteCount }
                : artifact.byteCount
        )
        do {
            try restoreVerifiedWorkspaceData(
                data,
                receipt: receipt,
                clearsRecoveryLockMarker: manifest.runtimeStateIncluded == true
            )
        } catch {
            var workspaceRollbackVerified = false
            var runtimeRollbackVerified = runtimeTransaction == nil
            if let fileStore = store as? FileDesktopStateStore {
                if let originalWorkspaceData {
                    do {
                        try fileStore.saveRecovered(originalWorkspaceData)
                        workspaceRollbackVerified = try fileStore.load() == originalWorkspaceData
                    } catch {
                        workspaceRollbackVerified = false
                    }
                }
                if let runtimeTransaction {
                    do {
                        try fileStore.rollbackRuntimeRestore(runtimeTransaction)
                        runtimeRollbackVerified = true
                    } catch {
                        runtimeRollbackVerified = false
                    }
                }
                if !workspaceRollbackVerified || !runtimeRollbackVerified {
                    try forceRecoveryReadOnlyAfterRollbackFailure(
                        fileStore: fileStore,
                        code: "restore-rollback-unverified"
                    )
                    throw DesktopModelRecoveryError.recoveryRollbackFailed
                }
            }
            throw error
        }
    }

    @discardableResult
    public func prepareReset(verifiedBackupAt bundleURL: URL) throws -> DesktopResetManifest {
        let manifest = try DesktopRecoveryService().prepareResetManifest(
            verifiedBackupAt: bundleURL,
            preparedAtUnixMillis: now()
        )
        try (store as? FileDesktopStateStore)?.persistResetManifest(manifest)
        return manifest
    }

    @discardableResult
    public func resetWorkspace(verifiedBackupAt bundleURL: URL) throws -> DesktopResetManifest {
        _ = try DesktopRecoveryService().validateBackup(at: bundleURL)
        guard let fileStore = store as? FileDesktopStateStore,
              let recoveryStore = store as? any DesktopRecoveryStateStoring else {
            throw DesktopModelRecoveryError.recoveryUnavailable
        }
        let runtimeLock = try fileStore.acquireExclusiveRuntimeRecoveryLock()
        defer { _ = runtimeLock }
        try fileStore.requireRuntimeQuiescent()
        guard let currentBackup = try fileStore.createPrivateBackupHistory(
            stateSchemaVersion: recoveryStatus?.detectedStateSchemaVersion ?? snapshot.version,
            createdAtUnixMillis: now(),
            includesRuntimeState: true
        ) else {
            throw DesktopModelRecoveryError.recoveryUnavailable
        }
        let manifest = DesktopResetManifest(
            resetID: UUID(),
            preparedAtUnixMillis: now(),
            verifiedBackupID: currentBackup.backupID,
            localArtifacts: currentBackup.artifacts
        )
        try fileStore.persistResetManifest(manifest)
        let originalWorkspaceData = try fileStore.load()
        let runtimeMoves: [DesktopRuntimeArchiveMove]
        do {
            runtimeMoves = try fileStore.archiveRuntimeState(resetID: manifest.resetID)
        } catch {
            if let recoveryError = error as? DesktopModelRecoveryError,
               recoveryError == .recoveryRollbackFailed {
                try forceRecoveryReadOnlyAfterRollbackFailure(
                    fileStore: fileStore,
                    code: "reset-runtime-archive-rollback-unverified"
                )
            }
            throw error
        }
        let starter = DesktopAppSnapshot.starter(now: now())
        let encoded = try encoder.encode(starter)
        do {
            try recoveryStore.saveRecovered(encoded)
            guard try recoveryStore.load() == encoded else {
                throw DesktopModelRecoveryError.persistenceVerificationFailed
            }
            try fileStore.clearRecoveryLockMarker()
        } catch {
            var workspaceRollbackVerified = false
            var runtimeRollbackVerified = false
            if let originalWorkspaceData {
                do {
                    try fileStore.saveRecovered(originalWorkspaceData)
                    workspaceRollbackVerified = try fileStore.load() == originalWorkspaceData
                } catch {
                    workspaceRollbackVerified = false
                }
            }
            do {
                try fileStore.restoreArchivedRuntimeState(runtimeMoves)
                runtimeRollbackVerified = true
            } catch {
                runtimeRollbackVerified = false
            }
            if !workspaceRollbackVerified || !runtimeRollbackVerified {
                try forceRecoveryReadOnlyAfterRollbackFailure(
                    fileStore: fileStore,
                    code: "reset-rollback-unverified"
                )
                throw DesktopModelRecoveryError.recoveryRollbackFailed
            }
            throw error
        }
        snapshot = starter
        resetComposerDraftCacheFromSnapshot()
        providerEventIDs = []
        recoveryStatus = nil
        persistenceError = nil
        return manifest
    }

    private func forceRecoveryReadOnlyAfterRollbackFailure(
        fileStore: FileDesktopStateStore,
        code: String
    ) throws {
        recoveryStatus = DesktopRecoveryStatus(
            reason: .runtimeRollbackUnverified,
            detectedStateSchemaVersion: snapshot.version,
            quarantineCreated: false,
            previousWorkspaceAvailable: false
        )
        persistenceError = DesktopModelRecoveryError.recoveryRollbackFailed.localizedDescription
        let event = DesktopRedactedDiagnosticEvent(
            category: "recovery",
            code: code,
            occurredAtUnixMillis: now()
        )
        do {
            try fileStore.persistRecoveryLockMarker(event)
        } catch {
            throw DesktopModelRecoveryError.recoveryRollbackFailed
        }
        try? fileStore.persistRecoveryFailureEvent(event)
    }

    public func redactedDiagnostics() -> String {
        let diagnosticsEncoder = JSONEncoder()
        diagnosticsEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? diagnosticsEncoder.encode(makeRedactedDiagnosticsReport()) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public func redactedSupportBundle() -> String {
        let receipts = (store as? FileDesktopStateStore)?.loadRedactedRecoveryReceiptDiagnostics() ?? .empty
        let bundle = DesktopRedactedDiagnosticsBundle(
            generatedAtUnixMillis: now(),
            report: makeRedactedDiagnosticsReport(),
            migrationReceipts: receipts.migrationReceipts,
            restoreReceipts: receipts.restoreReceipts,
            resetReceipts: receipts.resetReceipts,
            events: receipts.events,
            malformedReceiptCount: receipts.malformedReceiptCount,
            rejectedUnsafeReceiptCount: receipts.rejectedUnsafeReceiptCount,
            receiptScanTruncated: receipts.receiptScanTruncated
        )
        let diagnosticsEncoder = JSONEncoder()
        diagnosticsEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? diagnosticsEncoder.encode(bundle) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func makeRedactedDiagnosticsReport() -> DesktopDiagnosticsReport {
        DesktopDiagnosticsReport(
            schemaVersion: snapshot.version,
            generatedAtUnixMillis: now(),
            projectCount: snapshot.projects.count,
            activeThreadCount: activeThreads.count,
            archivedThreadCount: archivedThreads.count,
            unreadThreadCount: snapshot.threads.filter(\.unread).count,
            pendingApprovalCount: snapshot.operations.approvals.filter { $0.state == .awaitingApproval }.count,
            researchCount: snapshot.domains.research.count,
            emailDraftCount: snapshot.domains.emailDrafts.count,
            calendarProposalCount: snapshot.domains.calendarProposals.count,
            automationCount: snapshot.domains.automations.count,
            artifactCount: snapshot.operations.artifacts.count,
            auditRecordCount: snapshot.operations.audit.count,
            safeMode: snapshot.preferences.safeMode,
            persistenceHealthy: persistenceError == nil,
            relayState: snapshot.remote.relayStatus,
            queueState: snapshot.remote.queueStatus
        )
    }

    @discardableResult
    func mutate(_ change: (inout DesktopAppSnapshot) -> Void) -> Bool {
        guard recoveryStatus == nil else {
            persistenceError = "Kaname is keeping this recovery workspace read-only until verified state is restored or exported."
            return false
        }
        var changed = snapshot
        change(&changed)
        changed.operations.composerDrafts = composerDraftCache
        changed.lastSavedAtUnixMillis = now()
        do {
            try store.save(try encoder.encode(changed))
            snapshot = changed
            persistedComposerDraftGeneration = composerDraftGeneration
            composerDraftSaveTask?.cancel()
            composerDraftSaveTask = nil
            persistenceError = nil
            return true
        } catch {
            persistenceError = "Kaname could not save this local change. The previous durable workspace remains intact."
            return false
        }
    }

    @discardableResult
    private func mutateThread(id: String, change: (inout DesktopThread) -> Void) -> Bool {
        var didFindThread = false
        let persisted = mutate { workspace in
            let matches = workspace.threads.indices.filter { workspace.threads[$0].id == id }
            guard let index = matches.first else { return }
            change(&workspace.threads[index])
            didFindThread = true
        }
        return didFindThread && persisted
    }

    @discardableResult
    func mutateRecord<Record: Identifiable>(
        at keyPath: WritableKeyPath<DesktopAppSnapshot, [Record]>,
        id: String,
        change: (inout Record) -> Void,
        audit: DesktopAuditRecord? = nil
    ) -> Bool where Record.ID == String {
        var didFindRecord = false
        let persisted = mutate { snapshot in
            didFindRecord = snapshot.changeRecord(at: keyPath, id: id, change: change)
            if didFindRecord, let audit { snapshot.operations.audit.append(audit) }
        }
        return didFindRecord && persisted
    }

    private static func stableLocalDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func providerSessionDescriptor(provider: String) -> (
        capabilities: [String],
        limitations: [String]
    ) {
        switch provider.lowercased() {
        case "codex":
            (["Streaming", "Persistent resume", "Questions", "Approvals", "Diff events"], [])
        case "claude":
            (["Streaming", "Persistent resume", "Plan mode", "Subagent events"], ["Kaname keeps writes disabled until a worktree grant is approved"])
        case "opencode", "open code":
            (["Streaming", "Persistent resume", "Plan agent", "Model routing"], ["Some native event kinds remain provider-specific"])
        default:
            ([], ["This provider is not supported by the installed Kaname build"])
        }
    }

    private static let codingKnowledgeMaximumSourceCount = 64
    private static let codingKnowledgeMaximumCandidateCount = 64
    private static let codingKnowledgeMaximumSourceIDBytes = 256
    private static let codingKnowledgeMaximumTitleBytes = 240
    private static let codingKnowledgeMaximumPathBytes = 2_048
    private static let codingKnowledgeMaximumDigestBytes = 256
    private static let codingKnowledgeMaximumProvenanceBytes = 1_024
    private static let codingKnowledgeMaximumExcerptBytes = 8_192
    private static let codingKnowledgeMaximumSummaryBytes = 2_048
    private static let codingKnowledgeMaximumDetailBytes = 8_192
    private static let codingKnowledgeMaximumReasonBytes = 2_048

    private static func ensureCodingWorkflow(
        in snapshot: inout DesktopAppSnapshot,
        threadID: String,
        projectID: String?,
        timestamp: Int64
    ) {
        guard let thread = snapshot.threads.first(where: { $0.id == threadID }), thread.kind == .coding,
              !snapshot.operations.codingWorkflows.contains(where: { $0.threadID == threadID }) else { return }
        snapshot.operations.codingWorkflows.append(DesktopCodingWorkflowRecord(
            projectID: projectID ?? thread.projectID,
            threadID: threadID,
            createdAtUnixMillis: timestamp,
            updatedAtUnixMillis: timestamp
        ))
    }

    private static func hasAcceptedCodingWorktree(
        in snapshot: DesktopAppSnapshot,
        threadID: String
    ) -> Bool {
        guard let acceptedWorktreeID = snapshot.operations.codingKnowledgeLanes.first(where: {
            $0.threadID == threadID
        })?.acceptedWorktreeID else { return false }
        return snapshot.operations.worktrees.contains {
            $0.id == acceptedWorktreeID && $0.threadID == threadID && $0.state == .accepted
        }
    }

    private static func knowledgeApprovalTarget(path: String, baseDigest: String) -> String {
        "obsidian:\(path)#sha256=\(baseDigest)"
    }

    private static func applyKnowledgeApprovalDecision(
        in snapshot: inout DesktopAppSnapshot,
        approvalID: String,
        state: DesktopActionState,
        timestamp: Int64
    ) {
        let writeIndexes = snapshot.operations.knowledgeWrites.indices.filter {
            snapshot.operations.knowledgeWrites[$0].approvalID == approvalID
        }
        for writeIndex in writeIndexes {
            let writeID = snapshot.operations.knowledgeWrites[writeIndex].id
            let proposalID = snapshot.operations.knowledgeWrites[writeIndex].proposalID
            snapshot.operations.knowledgeWrites[writeIndex].state = state
            if let proposalIndex = snapshot.operations.knowledgeProposals.firstIndex(where: { $0.id == proposalID }) {
                snapshot.operations.knowledgeProposals[proposalIndex].state = state
            }
            for laneIndex in snapshot.operations.codingKnowledgeLanes.indices
            where snapshot.operations.codingKnowledgeLanes[laneIndex].writeID == writeID
                || snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID == proposalID {
                let threadID = snapshot.operations.codingKnowledgeLanes[laneIndex].threadID
                guard hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
                      snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge else { continue }
                if state == .approved {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .proposed
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "The exact knowledge write is approved but has not been applied or reconciled."
                } else if state == .rejected || state == .cancelled {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .needsReview
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = state == .rejected
                        ? "The exact knowledge write was rejected; revise it or record a reasoned waiver."
                        : "The exact knowledge-write approval expired; request a revised proposal or record a reasoned waiver."
                }
                snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            }
        }
    }

    private static func allowsExternalCodingTransition(
        from current: DesktopCodingWorkflowState,
        to next: DesktopCodingWorkflowState
    ) -> Bool {
        if current == next { return true }
        if next == .failed && current != .completed { return true }
        return switch (current, next) {
        case (.awaitingPlanApproval, .preparingImplementation),
             (.awaitingReview, .reviewingEvidence),
             (.reviewingEvidence, .awaitingReview),
             (.awaitingAcceptance, .reviewingEvidence):
            true
        default:
            false
        }
    }

    private static func setCodingWorkflow(
        in snapshot: inout DesktopAppSnapshot,
        threadID: String,
        projectID: String? = nil,
        state: DesktopCodingWorkflowState,
        reason: String? = nil,
        timestamp: Int64
    ) {
        guard let thread = snapshot.threads.first(where: { $0.id == threadID }), thread.kind == .coding else { return }
        ensureCodingWorkflow(in: &snapshot, threadID: threadID, projectID: projectID ?? thread.projectID, timestamp: timestamp)
        guard let index = snapshot.operations.codingWorkflows.firstIndex(where: { $0.threadID == threadID }) else { return }
        snapshot.operations.codingWorkflows[index].state = state
        if let reason {
            let cleanReason = normalized(reason)
            snapshot.operations.codingWorkflows[index].reason = cleanReason.isEmpty
                ? nil
                : KanameTextBounds.utf8Prefix(cleanReason, maximumBytes: codingKnowledgeMaximumReasonBytes)
        } else {
            snapshot.operations.codingWorkflows[index].reason = nil
        }
        snapshot.operations.codingWorkflows[index].updatedAtUnixMillis = timestamp
    }

    private static func boundedCodingKnowledgeSources(
        _ sources: [DesktopCodingKnowledgeConsultedSource]
    ) -> [DesktopCodingKnowledgeConsultedSource]? {
        var seen = Set<String>()
        var bounded: [DesktopCodingKnowledgeConsultedSource] = []
        bounded.reserveCapacity(sources.count)
        for source in sources {
            guard !normalized(source.sourceID).isEmpty, source.sourceID.utf8.count <= codingKnowledgeMaximumSourceIDBytes,
                  !normalized(source.title).isEmpty, source.title.utf8.count <= codingKnowledgeMaximumTitleBytes,
                  !normalized(source.path).isEmpty, source.path.utf8.count <= codingKnowledgeMaximumPathBytes,
                  !normalized(source.digest).isEmpty, source.digest.utf8.count <= codingKnowledgeMaximumDigestBytes,
                  !normalized(source.provenance).isEmpty, source.provenance.utf8.count <= codingKnowledgeMaximumProvenanceBytes,
                  source.excerpt.utf8.count <= codingKnowledgeMaximumExcerptBytes,
                  source.summary.utf8.count <= codingKnowledgeMaximumSummaryBytes else { return nil }
            let key = "\(source.sourceID)|\(source.path)|\(source.digest)"
            guard seen.insert(key).inserted else { continue }
            bounded.append(source)
            if bounded.count == codingKnowledgeMaximumSourceCount { break }
        }
        return bounded
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBoundedProviderIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueNormalized(
        _ values: [String],
        maximumCount: Int,
        maximumBytes: Int
    ) -> [String] {
        let values = unique(values.map(normalized).filter { !$0.isEmpty && $0.utf8.count <= maximumBytes })
        guard values.count > maximumCount else { return values }
        return Array(values[0..<maximumCount])
    }

    private static func provisionalConversationTitle(from firstMessage: String) -> String {
        let collapsed = firstMessage.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let maximumCharacters = 72
        guard collapsed.count > maximumCharacters else { return collapsed }
        return "\(String(collapsed.prefix(maximumCharacters)).trimmingCharacters(in: .whitespacesAndNewlines))…"
    }

    private static func sortedRecords<Record>(
        _ records: [Record],
        key: (Record) -> String
    ) -> [Record] {
        records.sorted {
            key($0).localizedCaseInsensitiveCompare(key($1)) == .orderedAscending
        }
    }

    private static func currentSnapshot(
        from data: Data,
        decoder: JSONDecoder,
        now: Int64
    ) throws -> (snapshot: DesktopAppSnapshot, didMigrate: Bool) {
        let decoded = try decoder.decode(DesktopAppSnapshot.self, from: data)
        if decoded.version == DesktopAppSnapshot.currentVersion { return (decoded, false) }
        return (try decoded.migratedToCurrent(now: now), true)
    }

    public static func declaredSchemaVersion(from data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? Int
    }

    private static func requireSingleRecoveryArtifact(
        kind: DesktopRecoveryArtifactKind,
        in manifest: DesktopBackupManifest
    ) throws -> DesktopRecoveryArtifactManifest {
        let matches = manifest.artifacts.filter { $0.kind == kind }
        guard matches.count == 1, let artifact = matches.first else {
            throw DesktopModelRecoveryError.restoreArtifactInvalid
        }
        return artifact
    }

    private func restoreVerifiedWorkspaceData(
        _ data: Data,
        receipt: DesktopRestoreReceipt?,
        clearsRecoveryLockMarker: Bool = false
    ) throws {
        let restored: (snapshot: DesktopAppSnapshot, didMigrate: Bool)
        do {
            restored = try Self.currentSnapshot(from: data, decoder: decoder, now: now())
        } catch {
            throw DesktopModelRecoveryError.restoreArtifactInvalid
        }
        let encoded = try encoder.encode(restored.snapshot)
        guard let recoveryStore = store as? any DesktopRecoveryStateStoring else {
            throw DesktopModelRecoveryError.recoveryUnavailable
        }
        try recoveryStore.saveRecovered(encoded)
        guard try recoveryStore.load() == encoded else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
        if restored.didMigrate, let fileStore = store as? FileDesktopStateStore {
            try fileStore.persistMigrationReceipt(DesktopMigrationReceipt(
                migrationID: UUID(),
                fromStateSchemaVersion: Self.declaredSchemaVersion(from: data) ?? 0,
                toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
                startedAtUnixMillis: now(),
                completedAtUnixMillis: now(),
                outcome: .applied,
                backupID: receipt?.backupID
            ))
        }
        if let receipt {
            try (store as? FileDesktopStateStore)?.persistRestoreReceipt(receipt)
        }
        if clearsRecoveryLockMarker {
            try (store as? FileDesktopStateStore)?.clearRecoveryLockMarker()
        }
        snapshot = restored.snapshot
        resetComposerDraftCacheFromSnapshot()
        providerEventIDs = Set(restored.snapshot.operations.providerEvents.map(\.id))
        recoveryStatus = nil
        persistenceError = nil
    }

    private func scheduleComposerDraftPersistence() {
        let generation = composerDraftGeneration
        composerDraftSaveTask?.cancel()
        composerDraftSaveTask = _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await _Concurrency.Task<Never, Never>.sleep(for: composerDraftSaveDelay)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard generation == composerDraftGeneration else { return }
            composerDraftSaveTask = nil
            _ = mutate { _ in }
        }
    }

    private func resetComposerDraftCacheFromSnapshot() {
        composerDraftSaveTask?.cancel()
        composerDraftSaveTask = nil
        composerDraftCache = snapshot.operations.composerDrafts
        composerDraftGeneration &+= 1
        persistedComposerDraftGeneration = composerDraftGeneration
    }
}

private enum DesktopModelError: Error {
    case unsupportedVersion
    case invalidState
}
