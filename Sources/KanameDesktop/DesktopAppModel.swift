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
}

public enum DesktopMessageRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case system
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
        self.updatedAtUnixMillis = updatedAtUnixMillis
        self.unread = unread
        self.messages = messages
        self.plan = plan
        self.evidence = evidence
    }
}

public struct DesktopProject: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var path: String?
    public var summary: String
    public var accent: String
    public var createdAtUnixMillis: Int64

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        path: String? = nil,
        summary: String,
        accent: String = "frost",
        createdAtUnixMillis: Int64
    ) {
        (self.id, self.name, self.path) = (id, name, path)
        (self.summary, self.accent, self.createdAtUnixMillis) = (summary, accent, createdAtUnixMillis)
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
    public static let currentVersion = 6

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
        guard (1...5).contains(version) else { throw DesktopModelError.unsupportedVersion }
        var migrated = self
        migrated.version = Self.currentVersion
        if migrated.domains == .empty {
            migrated.domains = .starter(now: now)
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

    public static func applicationSupport() -> FileDesktopStateStore {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return FileDesktopStateStore(
            fileURL: base
                .appendingPathComponent("Kaname", isDirectory: true)
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

    public func thread(id: String?) -> DesktopThread? {
        guard let id else { return nil }
        return snapshot.threads.first { $0.id == id }
    }

    public func project(id: String?) -> DesktopProject? {
        guard let id else { return nil }
        return snapshot.projects.first { $0.id == id }
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

    public func appendUserMessage(threadID: String, body: String) {
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBody.isEmpty, cleanBody.utf8.count <= 32_000 else { return }
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].messages.append(
                DesktopMessage(role: .user, body: cleanBody, createdAtUnixMillis: timestamp)
            )
            snapshot.threads[index].summary = cleanBody
            snapshot.threads[index].attention = .queued
            snapshot.threads[index].updatedAtUnixMillis = timestamp
            snapshot.threads[index].unread = false
        }
    }

    public func setAttention(threadID: String, attention: DesktopAttention) {
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].attention = attention
            snapshot.threads[index].updatedAtUnixMillis = now()
            if attention == .completed || attention == .archived {
                snapshot.threads[index].unread = false
            }
        }
    }

    public func markRead(threadID: String) {
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].unread = false
        }
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
        mutateDomainRecord(at: \.calendarSources, id: id) { source in
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
        mutateDomainRecord(at: \.automations, id: id) { rule in
            rule.status = paused ? .paused : .draft
        }
    }

    public func setSkillEnabled(id: String, enabled: Bool) {
        mutateDomainRecord(at: \.skills, id: id) { skill in
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
        mutate { snapshot in
            snapshot.operations.providerRuns.append(contentsOf: runs)
            snapshot.operations.comparisons.append(comparison)
        }
        return comparison.id
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

    private func mutateDomainRecord<Record: Identifiable>(
        at keyPath: WritableKeyPath<DesktopDomainSnapshot, [Record]>,
        id: String,
        change: (inout Record) -> Void
    ) where Record.ID == String {
        mutate { snapshot in
            guard let index = snapshot.domains[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { return }
            change(&snapshot.domains[keyPath: keyPath][index])
        }
    }

    private static func stableLocalDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
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
