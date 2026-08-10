import Combine
import CryptoKit
import Foundation

public enum DesktopAttention: String, Codable, CaseIterable, Equatable, Sendable {
    case needsResponse
    case needsApproval
    case running
    case queued
    case completed
    case failed
    case archived

    public var label: String {
        switch self {
        case .needsResponse: "Needs response"
        case .needsApproval: "Needs approval"
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
    let titleSource: DesktopConversationTitleSource?
    let updatedAtUnixMillis: Int64
    let unread: Bool
    let messages: [DesktopMessage]
    let plan: [DesktopPlanItem]
    let evidence: [DesktopEvidence]
}

public struct DesktopMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let role: DesktopMessageRole
    public let body: String
    public let createdAtUnixMillis: Int64

    public init(
        id: String = UUID().uuidString.lowercased(),
        role: DesktopMessageRole,
        body: String,
        createdAtUnixMillis: Int64
    ) {
        self.id = id
        self.role = role
        self.body = body
        self.createdAtUnixMillis = createdAtUnixMillis
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
    public var titleSource: DesktopConversationTitleSource
    public var updatedAtUnixMillis: Int64
    public var unread: Bool
    public var messages: [DesktopMessage]
    public var plan: [DesktopPlanItem]
    public var evidence: [DesktopEvidence]

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
        titleSource: DesktopConversationTitleSource = .manual,
        updatedAtUnixMillis: Int64,
        unread: Bool = false,
        messages: [DesktopMessage] = [],
        plan: [DesktopPlanItem] = [],
        evidence: [DesktopEvidence] = []
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
        self.titleSource = titleSource
        self.updatedAtUnixMillis = updatedAtUnixMillis
        self.unread = unread
        self.messages = messages
        self.plan = plan
        self.evidence = evidence
    }

    public init(from decoder: any Decoder) throws {
        let payload = try DesktopThreadPayload(from: decoder)
        self.init(
            id: payload.id,
            projectID: payload.projectID,
            title: payload.title,
            summary: payload.summary,
            kind: payload.kind,
            attention: payload.attention,
            provider: payload.provider,
            model: payload.model,
            reasoningEffort: payload.reasoningEffort ?? "xhigh",
            titleSource: payload.titleSource ?? .manual,
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

    public static func currentCheckpoint(now: Int64) -> DesktopRemoteStatus {
        DesktopRemoteStatus(
            relayStatus: "Hosted relay clean",
            enrollmentStatus: "Simulator qualified · physical device deferred",
            notificationStatus: "Privacy contract passed · APNs credentials deferred",
            queueStatus: "Restart-safe · 0 pending after terminal receipts",
            lastVerifiedAtUnixMillis: now,
            events: [
                DesktopRemoteEvent(
                    id: "remote-relay-rehearsal",
                    title: "Encrypted relay rehearsal",
                    detail: "Enrollment, edited queue, receipts, stale approval, rotation, revocation, and cleanup passed.",
                    state: .passed
                ),
                DesktopRemoteEvent(
                    id: "remote-restart-recovery",
                    title: "Restart recovery",
                    detail: "Enrollment, key custody, queue, receipts, history, and pending rotation recover safely.",
                    state: .passed
                ),
                DesktopRemoteEvent(
                    id: "remote-apns-contract",
                    title: "APNs payload contract",
                    detail: "Only a generic content-free attention hint is sent; encrypted work remains in the relay.",
                    state: .passed
                ),
                DesktopRemoteEvent(
                    id: "remote-physical-iphone",
                    title: "Physical iPhone qualification",
                    detail: "Deferred until a different iPhone is explicitly designated.",
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
    public static let currentVersion = 12

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
                    title: "Kaname desktop dogfood",
                    summary: "The polished desktop workspace is installed and ready for dogfooding.",
                    kind: .coding,
                    attention: .needsResponse,
                    provider: "Codex",
                    model: "Local development session",
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
                            body: "The persistent workspace, integrated safety surfaces, private local core, release packaging, and visual qualification are ready.",
                            createdAtUnixMillis: now - 1_000
                        ),
                    ],
                    plan: [
                        DesktopPlanItem(title: "Persistent desktop workspace", state: .complete),
                        DesktopPlanItem(title: "Integrated devices and remote health", state: .complete),
                        DesktopPlanItem(title: "Packaging and interactive QA", state: .complete),
                    ],
                    evidence: [
                        DesktopEvidence(label: "Swift tests", detail: "Full desktop suite passed", state: .passed),
                        DesktopEvidence(label: "Rust tests", detail: "26 tests passed", state: .passed),
                        DesktopEvidence(label: "Packaged app", detail: "Signed, installed, and visually qualified", state: .passed),
                        DesktopEvidence(label: "Local core", detail: "F-01 through F-14 replayed through Mach XPC", state: .passed),
                    ]
                ),
                DesktopThread(
                    id: "thread-phase3-mobile",
                    projectID: project.id,
                    title: "Phase 3 mobile qualification",
                    summary: "Simulator, hosted relay, reconciliation, recovery, and cleanup are complete.",
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
                        DesktopEvidence(label: "Hosted relay", detail: "Clean after bounded qualification", state: .passed),
                        DesktopEvidence(label: "Simulator recovery", detail: "Restart and reconciliation passed", state: .passed),
                        DesktopEvidence(label: "Physical device", detail: "Explicitly deferred", state: .notRun),
                    ]
                ),
                DesktopThread(
                    id: "thread-local-core",
                    projectID: project.id,
                    title: "Local authority health",
                    summary: "Signed XPC and durable Rust journal evidence remain available for inspection.",
                    kind: .coding,
                    attention: .completed,
                    provider: "Kaname local core",
                    model: "Provider-free",
                    updatedAtUnixMillis: now - 120_000,
                    evidence: [
                        DesktopEvidence(label: "Local core", detail: "Phase 1 acceptance corpus passed", state: .passed),
                        DesktopEvidence(label: "Codex adapter", detail: "Phase 2 accepted workflow passed", state: .passed),
                    ]
                ),
            ],
            remote: .currentCheckpoint(now: now),
            preferences: DesktopPreferences(),
            domains: .starter(now: now),
            operations: .empty,
            lastSavedAtUnixMillis: now
        )
    }

    func migratedToCurrent(now: Int64) throws -> DesktopAppSnapshot {
        guard (1...11).contains(version) else { throw DesktopModelError.unsupportedVersion }
        var migrated = self
        migrated.version = Self.currentVersion
        if migrated.domains == .empty {
            migrated.domains = .starter(now: now)
        }
        if let index = migrated.projects.firstIndex(where: { $0.id == "project-kaname" }),
           migrated.projects[index].context == .empty {
            migrated.projects[index].context = DesktopProjectContext(
                instructionReferences: ["AGENTS.md"],
                knowledgeSourceIDs: ["knowledge-coding-ade", "knowledge-kaname-repository"],
                skillIDs: ["skill-mori-review", "skill-obsidian"]
            )
        }
        migrated.lastSavedAtUnixMillis = now

        if let index = migrated.threads.firstIndex(where: { $0.id == "thread-desktop-dogfood" }) {
            migrated.threads[index].summary = "The polished desktop workspace is installed and ready for dogfooding."
            migrated.threads[index].attention = .needsResponse
            migrated.threads[index].unread = true
            migrated.threads[index].updatedAtUnixMillis = now
            if !migrated.threads[index].messages.contains(where: { $0.id == "message-desktop-ready" }) {
                migrated.threads[index].messages.append(
                    DesktopMessage(
                        id: "message-desktop-ready",
                        role: .assistant,
                        body: "The persistent workspace, integrated safety surfaces, private local core, release packaging, and visual qualification are ready.",
                        createdAtUnixMillis: now
                    )
                )
            }
            migrated.threads[index].plan = [
                DesktopPlanItem(title: "Persistent desktop workspace", state: .complete),
                DesktopPlanItem(title: "Integrated devices and remote health", state: .complete),
                DesktopPlanItem(title: "Packaging and interactive QA", state: .complete),
            ]
            migrated.threads[index].evidence = [
                        DesktopEvidence(label: "Swift tests", detail: "Full desktop suite passed", state: .passed),
                DesktopEvidence(label: "Rust tests", detail: "26 tests passed", state: .passed),
                DesktopEvidence(label: "Packaged app", detail: "Signed, installed, and visually qualified", state: .passed),
                DesktopEvidence(label: "Local core", detail: "F-01 through F-14 replayed through Mach XPC", state: .passed),
            ]
        }
        return migrated
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

public final class FileDesktopStateStore: DesktopRecoveryStateStoring {
    public let fileURL: URL

    public var recoveryFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("workspace.previous.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func save(_ data: Data) throws {
        try prepareDirectory()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let previous = try Data(contentsOf: fileURL)
            try writePrivate(previous, to: recoveryFileURL)
        }
        try writePrivate(data, to: fileURL)
    }

    public func loadRecovery() throws -> Data? {
        guard FileManager.default.fileExists(atPath: recoveryFileURL.path) else { return nil }
        return try Data(contentsOf: recoveryFileURL)
    }

    public func saveRecovered(_ data: Data) throws {
        try prepareDirectory()
        try writePrivate(data, to: fileURL)
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

@MainActor
public final class DesktopAppModel: ObservableObject {
    @Published public private(set) var snapshot: DesktopAppSnapshot
    @Published public private(set) var persistenceError: String?

    private let store: any DesktopStateStoring
    private let now: () -> Int64
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        store: any DesktopStateStoring = FileDesktopStateStore.applicationSupport(),
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.store = store
        self.now = now
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        do {
            if let data = try store.load() {
                let restored = try Self.currentSnapshot(from: data, decoder: decoder, now: now())
                if restored.didMigrate {
                    try store.save(try encoder.encode(restored.snapshot))
                }
                self.snapshot = restored.snapshot
            } else {
                let starter = DesktopAppSnapshot.starter(now: now())
                self.snapshot = starter
                try store.save(try encoder.encode(starter))
            }
        } catch {
            if let recoveryStore = store as? any DesktopRecoveryStateStoring,
               let recoveryData = try? recoveryStore.loadRecovery(),
               let recovered = try? Self.currentSnapshot(from: recoveryData, decoder: decoder, now: now()) {
                self.snapshot = recovered.snapshot
                try? recoveryStore.saveRecovered(encoder.encode(recovered.snapshot))
                self.persistenceError = "Kaname recovered the previous private workspace after the newest local state could not be restored."
            } else {
                self.snapshot = DesktopAppSnapshot.starter(now: now())
                self.persistenceError = "Kaname opened a safe starter workspace because local state could not be restored."
            }
        }
    }

    public var activeThreads: [DesktopThread] {
        snapshot.threads
            .filter { $0.attention != .archived }
            .sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }
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

    public func createConversation(kind: DesktopWorkKind, projectID: String?) -> String {
        let timestamp = now()
        let thread = DesktopThread(
            projectID: projectID,
            title: kind.newConversationTitle,
            summary: "Ready for your first message.",
            kind: kind,
            attention: .queued,
            provider: project(id: projectID)?.context.defaultProvider ?? "Codex",
            model: project(id: projectID)?.context.defaultModel ?? "Use provider default",
            titleSource: .placeholder,
            updatedAtUnixMillis: timestamp
        )
        mutate { $0.threads.append(thread) }
        return thread.id
    }

    @discardableResult
    public func appendUserMessage(threadID: String, body: String) -> String? {
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBody.isEmpty, cleanBody.utf8.count <= 32_000 else { return nil }
        let timestamp = now()
        let message = DesktopMessage(role: .user, body: cleanBody, createdAtUnixMillis: timestamp)
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            let shouldProjectTitle = snapshot.threads[index].title == snapshot.threads[index].kind.newConversationTitle
                && !snapshot.threads[index].messages.contains { $0.role == .user }
            snapshot.threads[index].messages.append(message)
            if shouldProjectTitle {
                snapshot.threads[index].title = Self.provisionalConversationTitle(from: cleanBody)
                snapshot.threads[index].titleSource = .provisional
            }
            snapshot.threads[index].summary = cleanBody
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
        reasoningEffort: String
    ) -> Bool {
        let cleanProvider = Self.normalized(provider)
        let cleanModel = Self.normalized(model)
        let cleanReasoning = Self.normalized(reasoningEffort).lowercased()
        guard !cleanProvider.isEmpty, cleanProvider.utf8.count <= 120,
              !cleanModel.isEmpty, cleanModel.utf8.count <= 200,
              ["low", "medium", "high", "xhigh"].contains(cleanReasoning),
              !snapshot.operations.providerRuns.contains(where: { $0.threadID == id && $0.state == .running }) else {
            return false
        }
        return mutateThread(id: id) { thread in
            thread.provider = cleanProvider
            thread.model = cleanModel
            thread.reasoningEffort = cleanReasoning
            thread.updatedAtUnixMillis = now()
        }
    }

    public func applyProviderGeneratedTitle(threadID: String, title: String) -> Bool {
        let cleanTitle = Self.generatedConversationTitle(from: title)
        guard !cleanTitle.isEmpty else { return false }
        guard thread(id: threadID)?.titleSource == .provisional else { return false }
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

    public func composerDraft(threadID: String) -> String {
        snapshot.operations.composerDrafts[threadID] ?? ""
    }

    @discardableResult
    public func updateComposerDraft(threadID: String, body: String) -> Bool {
        guard snapshot.threads.contains(where: { $0.id == threadID }), body.utf8.count <= 32_000 else { return false }
        mutate { snapshot in
            if body.isEmpty {
                snapshot.operations.composerDrafts.removeValue(forKey: threadID)
            } else {
                snapshot.operations.composerDrafts[threadID] = body
            }
        }
        return persistenceError == nil
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
    public func enqueueProviderRun(threadID: String, sourceMessageID: String) -> String? {
        guard let thread = thread(id: threadID),
              let message = thread.messages.first(where: { $0.id == sourceMessageID && $0.role == .user }) else {
            return nil
        }
        let run = DesktopProviderRunRecord(
            id: UUID().uuidString.lowercased(),
            threadID: threadID,
            sourceMessageID: sourceMessageID,
            provider: thread.provider,
            model: thread.model,
            reasoningEffort: thread.reasoningEffort,
            briefDigest: Self.stableLocalDigest(message.body),
            contextReferenceCount: providerContextReferenceCount(for: thread),
            tokenUsage: nil,
            costSummary: "Pending",
            state: .proposed,
            startedAtUnixMillis: now(),
            completedAtUnixMillis: nil
        )
        mutate { snapshot in
            snapshot.operations.providerRuns.append(run)
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            if !snapshot.operations.providerRuns.contains(where: {
                $0.threadID == threadID && $0.id != run.id && $0.state == .running
            }) {
                snapshot.threads[index].attention = .queued
            }
            snapshot.threads[index].updatedAtUnixMillis = now()
        }
        return run.id
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
        snapshot.operations.providerRuns
            .filter {
                guard $0.threadID == threadID, $0.nativeThreadID != nil else { return false }
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
        guard event.detail.utf8.count <= 65_536,
              event.rawPayloadBase64?.utf8.count ?? 0 <= 360_000 else { return false }
        var inserted = false
        mutate { snapshot in
            guard !snapshot.operations.providerEvents.contains(where: { $0.id == event.id }) else { return }
            snapshot.operations.providerEvents.append(event)
            inserted = true
            guard let delta = assistantDelta, !delta.isEmpty,
                  let threadIndex = snapshot.threads.firstIndex(where: { $0.id == event.threadID }) else { return }
            let messageID = "assistant-\(event.runID)"
            if let messageIndex = snapshot.threads[threadIndex].messages.firstIndex(where: { $0.id == messageID }) {
                let current = snapshot.threads[threadIndex].messages[messageIndex]
                snapshot.threads[threadIndex].messages[messageIndex] = DesktopMessage(
                    id: current.id,
                    role: .assistant,
                    body: String((current.body + delta).prefix(262_144)),
                    createdAtUnixMillis: current.createdAtUnixMillis
                )
            } else {
                snapshot.threads[threadIndex].messages.append(
                    DesktopMessage(
                        id: messageID,
                        role: .assistant,
                        body: String(delta.prefix(262_144)),
                        createdAtUnixMillis: event.createdAtUnixMillis
                    )
                )
            }
            snapshot.threads[threadIndex].summary = "Kaname is responding…"
            snapshot.threads[threadIndex].updatedAtUnixMillis = event.createdAtUnixMillis
        }
        return inserted
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
                threadSummary = assistant.map(Self.provisionalConversationTitle) ?? "Provider completed."
                attention = .needsResponse
            case let .stopped(interrupted, error):
                snapshot.operations.providerRuns[index].state = interrupted ? .interrupted : .failed
                snapshot.operations.providerRuns[index].errorSummary = error
                snapshot.operations.providerRuns[index].costSummary = interrupted ? "Interrupted" : "Failed"
                sessionState = interrupted ? .recoverable : .interrupted
                threadSummary = interrupted ? "Provider turn interrupted. You can retry it." : error
                attention = interrupted ? .needsResponse : .failed
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
        guard snapshot.operations.providerRuns.contains(where: { $0.state == .running }) else { return }
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
                }
            }
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
              [.failed, .interrupted].contains(run.state) else { return nil }
        return enqueueProviderRun(threadID: threadID, sourceMessageID: sourceMessageID)
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
    public func createProject(name: String, path: String?, summary: String) -> String? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf8.count <= 120 else { return nil }
        let cleanPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = DesktopProject(
            name: cleanName,
            path: cleanPath?.isEmpty == false ? cleanPath : nil,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAtUnixMillis: now()
        )
        mutate { $0.projects.append(project) }
        return project.id
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
            snapshot.domains.calendarSources = Self.sortedRecords(merged) {
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
        recurrence: String
    ) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= 200,
              (1...10_080).contains(durationMinutes),
              TimeZone(identifier: timeZoneIdentifier) != nil else { return nil }
        let proposal = DesktopCalendarProposal(
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
        mutate { $0.domains.calendarProposals.append(proposal) }
        return proposal.id
    }

    @discardableResult
    public func createAutomation(
        name: String,
        schedule: String,
        timeZoneIdentifier: String,
        actionSummary: String,
        missedRunPolicy: DesktopAutomationRule.MissedRunPolicy
    ) -> String? {
        let fields = [name, schedule, actionSummary].map(Self.normalized)
        guard fields.allSatisfy({ !$0.isEmpty }),
              TimeZone(identifier: timeZoneIdentifier) != nil else { return nil }
        let rule = DesktopAutomationRule(
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
        mutate { $0.domains.automations.append(rule) }
        return rule.id
    }

    public func setAutomationPaused(id: String, paused: Bool) {
        mutateRecord(at: \.domains.automations, id: id) { rule in
            rule.status = paused ? .paused : .draft
        }
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

    @discardableResult
    public func createKnowledgeProposal(
        sourceID: String?,
        title: String,
        target: String,
        summary: String,
        proposedContent: String,
        baseRevision: String
    ) -> String? {
        guard !Self.normalized(title).isEmpty,
              !Self.normalized(target).isEmpty,
              !Self.normalized(proposedContent).isEmpty else { return nil }
        let proposal = DesktopKnowledgeProposal(
            id: UUID().uuidString.lowercased(),
            knowledgeSourceID: sourceID,
            title: Self.normalized(title),
            target: Self.normalized(target),
            summary: Self.normalized(summary),
            proposedContent: proposedContent,
            baseRevision: Self.normalized(baseRevision),
            state: .proposed,
            createdAtUnixMillis: now()
        )
        mutate { $0.operations.knowledgeProposals.append(proposal) }
        return proposal.id
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
    ) -> String {
        let record = DesktopKnowledgeWriteRecord(
            id: UUID().uuidString.lowercased(),
            proposalID: proposalID,
            approvalID: nil,
            targetPath: targetPath,
            baseDigest: baseDigest,
            proposedDigest: proposedDigest,
            diffSummary: diffSummary,
            unifiedDiff: unifiedDiff,
            state: .proposed,
            currentDigest: nil,
            createdAtUnixMillis: now(),
            reconciledAtUnixMillis: nil
        )
        mutate { $0.operations.knowledgeWrites.append(record) }
        return record.id
    }

    public func attachKnowledgeApproval(writeID: String, approvalID: String) {
        mutate { snapshot in
            guard let index = snapshot.operations.knowledgeWrites.firstIndex(where: { $0.id == writeID }) else { return }
            snapshot.operations.knowledgeWrites[index].approvalID = approvalID
            snapshot.operations.knowledgeWrites[index].state = .awaitingApproval
            if let proposalIndex = snapshot.operations.knowledgeProposals.firstIndex(where: {
                $0.id == snapshot.operations.knowledgeWrites[index].proposalID
            }) { snapshot.operations.knowledgeProposals[proposalIndex].state = .awaitingApproval }
        }
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
            snapshot.operations.knowledgeWrites[index].state = state
            snapshot.operations.knowledgeWrites[index].currentDigest = currentDigest
            snapshot.operations.knowledgeWrites[index].reconciledAtUnixMillis = timestamp
            if let proposalIndex = snapshot.operations.knowledgeProposals.firstIndex(where: {
                $0.id == snapshot.operations.knowledgeWrites[index].proposalID
            }) { snapshot.operations.knowledgeProposals[proposalIndex].state = state }
            if let documentIndex = snapshot.operations.knowledgeDocuments.firstIndex(where: {
                $0.path == snapshot.operations.knowledgeWrites[index].targetPath
            }) { snapshot.operations.knowledgeDocuments[documentIndex].conflictDigest = state == .failed ? currentDigest : nil }
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "knowledge",
                action: "write reconciliation",
                target: snapshot.operations.knowledgeWrites[index].targetPath,
                state: state,
                detail: detail,
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
            let state: DesktopActionState = approved ? .approved : .rejected
            snapshot.operations.approvals[index].state = state
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
                let threadID = UUID().uuidString.lowercased()
                let messageID = UUID().uuidString.lowercased()
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
        title: String,
        detail: String,
        state: DesktopSubagentState
    ) {
        let id = "subagent-\(Self.stableLocalDigest("\(runID)|\(nativeID)"))"
        let timestamp = now()
        mutate { snapshot in
            if let index = snapshot.operations.subagents.firstIndex(where: { $0.id == id }) {
                snapshot.operations.subagents[index].detail = String(detail.prefix(8_192))
                snapshot.operations.subagents[index].state = state
                snapshot.operations.subagents[index].completedAtUnixMillis = [.completed, .failed, .interrupted].contains(state) ? timestamp : nil
            } else {
                snapshot.operations.subagents.append(DesktopSubagentRecord(
                    id: id,
                    threadID: threadID,
                    runID: runID,
                    parentID: nil,
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
        mutate { snapshot in
            snapshot.operations.automationRuns.append(run)
            snapshot.domains.automations = snapshot.domains.automations.map { automation in
                var updated = automation
                if updated.id == id { updated.lastResult = "Dry run passed" }
                return updated
            }
        }
        return run.id
    }

    public func clearPersistenceError() {
        persistenceError = nil
    }

    public func redactedDiagnostics() -> String {
        let report = DesktopDiagnosticsReport(
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
        let diagnosticsEncoder = JSONEncoder()
        diagnosticsEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? diagnosticsEncoder.encode(report) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func mutate(_ change: (inout DesktopAppSnapshot) -> Void) {
        var changed = snapshot
        change(&changed)
        changed.lastSavedAtUnixMillis = now()
        do {
            try store.save(try encoder.encode(changed))
            snapshot = changed
            persistenceError = nil
        } catch {
            persistenceError = "Kaname could not save this local change. The previous durable workspace remains intact."
        }
    }

    @discardableResult
    private func mutateThread(id: String, change: (inout DesktopThread) -> Void) -> Bool {
        var didFindThread = false
        mutate { workspace in
            let matches = workspace.threads.indices.filter { workspace.threads[$0].id == id }
            guard let index = matches.first else { return }
            change(&workspace.threads[index])
            didFindThread = true
        }
        return didFindThread
    }

    private func mutateRecord<Record: Identifiable>(
        at keyPath: WritableKeyPath<DesktopAppSnapshot, [Record]>,
        id: String,
        change: (inout Record) -> Void
    ) where Record.ID == String {
        mutate { snapshot in
            guard let index = snapshot[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { return }
            change(&snapshot[keyPath: keyPath][index])
        }
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

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func generatedConversationTitle(from value: String) -> String {
        var collapsed = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        collapsed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`#* "))
        if collapsed.lowercased().hasPrefix("title:") {
            collapsed = String(collapsed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let maximumCharacters = 80
        guard collapsed.count > maximumCharacters else { return collapsed }
        return String(collapsed.prefix(maximumCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
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
}

private enum DesktopModelError: Error {
    case unsupportedVersion
}
