import Foundation
@testable import KanameDesktop
import Testing

@MainActor
struct DesktopAppModelTests {
    @Test
    func localThreadsProjectsAndMessagesSurviveRestart() throws {
        let store = MemoryDesktopStateStore()
        var clock: Int64 = 1_000
        let model = DesktopAppModel(store: store, now: { clock })

        clock += 1
        let projectID = try #require(
            model.createProject(
                name: "Desktop dogfood",
                path: "/tmp/kaname-desktop-test",
                summary: "Persistent local workspace"
            )
        )
        clock += 1
        let threadID = try #require(
            model.createThread(title: "Use Kaname tomorrow", kind: .planning, projectID: projectID)
        )
        clock += 1
        model.appendUserMessage(threadID: threadID, body: "Keep this exact local note after restart.")
        model.setAttention(threadID: threadID, attention: .needsResponse)

        let restored = DesktopAppModel(store: store, now: { 2_000 })
        let thread = try #require(restored.thread(id: threadID))

        #expect(restored.project(id: projectID)?.name == "Desktop dogfood")
        #expect(thread.projectID == projectID)
        #expect(thread.messages.last?.body == "Keep this exact local note after restart.")
        #expect(thread.attention == .needsResponse)
        #expect(restored.persistenceError == nil)
    }

    @Test
    func invalidStateFallsBackWithoutOverwritingTheLastDurableBytes() {
        let invalid = Data("not-json".utf8)
        let store = MemoryDesktopStateStore(data: invalid)
        let model = DesktopAppModel(store: store, now: { 1_000 })

        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(!model.snapshot.threads.isEmpty)
        #expect(model.persistenceError != nil)
        #expect(store.data == invalid)
    }

    @Test
    func versionOneWorkspaceMigratesWithoutDroppingUserContent() throws {
        var versionOne = DesktopAppSnapshot.starter(now: 1_000)
        versionOne.version = 1
        versionOne.projects.append(
            DesktopProject(name: "Preserved project", summary: "User-owned", createdAtUnixMillis: 1_001)
        )
        versionOne.threads.append(
            DesktopThread(
                title: "Preserved thread",
                summary: "User-owned",
                kind: .research,
                attention: .queued,
                updatedAtUnixMillis: 1_002
            )
        )
        let store = MemoryDesktopStateStore(data: try JSONEncoder().encode(versionOne))

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(model.snapshot.projects.contains { $0.name == "Preserved project" })
        #expect(model.snapshot.threads.contains { $0.title == "Preserved thread" })
        #expect(model.thread(id: "thread-desktop-dogfood")?.plan.allSatisfy { $0.state == .complete } == true)
        #expect(model.thread(id: "thread-desktop-dogfood")?.evidence.allSatisfy { $0.state == .passed } == true)
        #expect(store.data != nil)
    }

    @Test
    func searchArchiveAndPrivacyPreferencesRemainCoherent() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 1_000 })
        let threadID = try #require(
            model.createThread(title: "Searchable recovery plan", kind: .coding, projectID: "project-kaname")
        )
        model.appendUserMessage(threadID: threadID, body: "Unique reconciliation marker")

        #expect(model.threads(matching: "unique reconciliation marker").map(\.id) == [threadID])
        model.setAttention(threadID: threadID, attention: .archived)
        #expect(model.threads(matching: "unique reconciliation marker").isEmpty)
        #expect(model.archivedThreads.map(\.id).contains(threadID))

        var preferences = model.snapshot.preferences
        preferences.previewPrivacy = .safeSummary
        preferences.showTechnicalDetails = true
        model.updatePreferences(preferences)

        let restored = DesktopAppModel(store: store, now: { 2_000 })
        #expect(restored.snapshot.preferences == preferences)
    }

    @Test
    func fileStoreUsesPrivateDirectoryAndFileModes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-desktop-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspace.json")
        let store = FileDesktopStateStore(fileURL: file)
        let expected = Data("private-local-workspace".utf8)

        try store.save(expected)

        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        )
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        )
        #expect(try store.load() == expected)
        #expect(directoryMode.intValue == 0o700)
        #expect(fileMode.intValue == 0o600)
    }
}

private final class MemoryDesktopStateStore: DesktopStateStoring {
    var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}
