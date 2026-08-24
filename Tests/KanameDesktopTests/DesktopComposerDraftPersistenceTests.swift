@testable import KanameDesktop
import Combine
import Foundation
import Testing

struct DesktopComposerDraftPersistenceTests {
    @Test
    @MainActor
    func idleCheckpointPersistsOnlyTheLatestGeneration() async throws {
        let store = CountingComposerDesktopStateStore()
        let model = DesktopAppModel(
            store: store,
            now: { 500 },
            composerDraftSaveDelay: .zero
        )
        let threadID = model.createConversation(kind: .coding, projectID: nil)
        store.resetSaveCount()

        for index in 0..<100 {
            #expect(model.updateComposerDraft(threadID: threadID, body: "Generation \(index)"))
        }
        for _ in 0..<1_000 where store.saveCount == 0 {
            await _Concurrency.Task<Never, Never>.yield()
        }

        #expect(store.saveCount == 1)
        #expect(model.snapshot.operations.composerDrafts[threadID] == "Generation 99")
    }

    @Test
    @MainActor
    func rapidEditsStayInMemoryAndCoalesceIntoOneCheckpoint() throws {
        let store = CountingComposerDesktopStateStore()
        var clock: Int64 = 1_000
        let model = DesktopAppModel(
            store: store,
            now: {
                defer { clock += 1 }
                return clock
            },
            composerDraftSaveDelay: .seconds(60)
        )
        let threadID = model.createConversation(kind: .coding, projectID: nil)
        store.resetSaveCount()
        let initialLastSaved = model.snapshot.lastSavedAtUnixMillis
        var publicationCount = 0
        let observation = model.objectWillChange.sink { publicationCount += 1 }

        for index in 0..<100 {
            #expect(model.updateComposerDraft(threadID: threadID, body: "Draft \(index)"))
        }

        #expect(model.composerDraft(threadID: threadID) == "Draft 99")
        #expect(model.snapshot.operations.composerDrafts[threadID] == nil)
        #expect(model.snapshot.lastSavedAtUnixMillis == initialLastSaved)
        #expect(store.saveCount == 0)
        #expect(publicationCount == 0)

        #expect(model.flushComposerDrafts())
        #expect(store.saveCount == 1)
        #expect(model.snapshot.operations.composerDrafts[threadID] == "Draft 99")
        #expect(model.snapshot.lastSavedAtUnixMillis > initialLastSaved)
        withExtendedLifetime(observation) {}
    }

    @Test
    @MainActor
    func ordinaryWorkspaceMutationCheckpointsPendingDraftWithoutAnExtraSave() throws {
        let store = CountingComposerDesktopStateStore()
        let model = DesktopAppModel(
            store: store,
            now: { 4_000 },
            composerDraftSaveDelay: .seconds(60)
        )
        let threadID = model.createConversation(kind: .coding, projectID: nil)
        store.resetSaveCount()

        #expect(model.updateComposerDraft(threadID: threadID, body: "Fold me into the next save"))
        #expect(model.renameThread(id: threadID, title: "Renamed"))
        #expect(store.saveCount == 1)

        #expect(model.flushComposerDrafts())
        #expect(store.saveCount == 1)
        #expect(DesktopAppModel(store: store, now: { 4_001 }).composerDraft(threadID: threadID) == "Fold me into the next save")
    }

    @Test
    @MainActor
    func failedCheckpointKeepsVisibleTextAndExplicitFlushRetriesIt() throws {
        let store = CountingComposerDesktopStateStore()
        let model = DesktopAppModel(
            store: store,
            now: { 5_000 },
            composerDraftSaveDelay: .seconds(60)
        )
        let threadID = model.createConversation(kind: .coding, projectID: nil)
        store.resetSaveCount()
        store.failsSave = true

        #expect(model.updateComposerDraft(threadID: threadID, body: "Keep this visible"))
        #expect(model.flushComposerDrafts() == false)

        #expect(store.saveCount == 1)
        #expect(model.composerDraft(threadID: threadID) == "Keep this visible")
        #expect(model.snapshot.operations.composerDrafts[threadID] == nil)
        #expect(model.persistenceError != nil)

        store.failsSave = false
        #expect(model.flushComposerDrafts())
        #expect(store.saveCount == 2)
        #expect(model.persistenceError == nil)
        #expect(DesktopAppModel(store: store, now: { 5_001 }).composerDraft(threadID: threadID) == "Keep this visible")
    }
}

private final class CountingComposerDesktopStateStore: DesktopStateStoring {
    private(set) var data: Data?
    private(set) var saveCount = 0
    var failsSave = false

    func load() throws -> Data? { data }

    func save(_ data: Data) throws {
        saveCount += 1
        if failsSave { throw CountingComposerStoreError.saveFailed }
        self.data = data
    }

    func resetSaveCount() {
        saveCount = 0
    }
}

private enum CountingComposerStoreError: Error {
    case saveFailed
}
