import Combine
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
}

public struct DesktopAppSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var projects: [DesktopProject]
    public var threads: [DesktopThread]
    public var remote: DesktopRemoteStatus
    public var preferences: DesktopPreferences
    public var lastSavedAtUnixMillis: Int64

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
                        DesktopEvidence(label: "Swift tests", detail: "66 tests passed", state: .passed),
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
            lastSavedAtUnixMillis: now
        )
    }

    func migratedToCurrent(now: Int64) throws -> DesktopAppSnapshot {
        guard version == 1 else { throw DesktopModelError.unsupportedVersion }
        var migrated = self
        migrated.version = Self.currentVersion
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
                DesktopEvidence(label: "Swift tests", detail: "66 tests passed", state: .passed),
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

public final class FileDesktopStateStore: DesktopStateStoring {
    public let fileURL: URL

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
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
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
                var restored = try decoder.decode(DesktopAppSnapshot.self, from: data)
                if restored.version != DesktopAppSnapshot.currentVersion {
                    restored = try restored.migratedToCurrent(now: now())
                    try store.save(try encoder.encode(restored))
                }
                self.snapshot = restored
            } else {
                let starter = DesktopAppSnapshot.starter(now: now())
                self.snapshot = starter
                try store.save(try encoder.encode(starter))
            }
        } catch {
            self.snapshot = DesktopAppSnapshot.starter(now: now())
            self.persistenceError = "Kaname opened a safe starter workspace because local state could not be restored."
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

    public func clearPersistenceError() {
        persistenceError = nil
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
}

private enum DesktopModelError: Error {
    case unsupportedVersion
}
