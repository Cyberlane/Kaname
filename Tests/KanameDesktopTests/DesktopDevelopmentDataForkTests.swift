import Foundation
import Testing
@testable import KanameConnectivity
@testable import KanameDesktop
@testable import KanameWorkflowHost

@MainActor
struct DesktopDevelopmentDataForkTests {
    @Test
    func stableSnapshotBecomesAnIndependentInertDevelopmentFork() throws {
        let base = try TestTemporaryDirectory.make(prefix: "kaname-development-fork")
        defer { try? FileManager.default.removeItem(at: base) }
        let stable = KanameDesktopEnvironment(channel: .stable, applicationSupportDirectory: base)
        let development = KanameDesktopEnvironment(channel: .development, applicationSupportDirectory: base)
        let stableStore = FileDesktopStateStore(fileURL: stable.workspaceFileURL)
        let stableModel = DesktopAppModel(store: stableStore, now: { 1_000 })

        #expect(stableModel.updateThreadRuntime(
            id: "thread-desktop-dogfood",
            provider: "Codex",
            model: "Stable model",
            reasoningEffort: "high",
            runtimeMode: .fullAccess,
            networkAccess: true
        ))
        let automationID = try #require(stableModel.createAutomation(
            name: "Stable morning check",
            schedule: "Once",
            timeZoneIdentifier: "UTC",
            actionSummary: "Show a local reminder",
            missedRunPolicy: .skip,
            scheduleSpec: .anchored(
                frequency: .once,
                hour: 9,
                minute: 0,
                onceAtUnixMillis: 100_000
            ),
            actionKind: .notification,
            authority: .localOnly
        ))
        #expect(stableModel.activateAutomation(id: automationID, approvalID: nil))

        let workflowLibrary = stable.applicationSupportRoot
            .appendingPathComponent("Workflows/workflow-library.sqlite")
        let workflowObject = stable.applicationSupportRoot
            .appendingPathComponent("Objects/blobs/object.bin")
        let queuedProviderRequest = stable.applicationSupportRoot
            .appendingPathComponent("ConversationService/thread/private-request.json")
        try write(Data("stable workflow library".utf8), to: workflowLibrary)
        try write(Data("stable workflow object".utf8), to: workflowObject)
        try write(Data("must not be activated in Dev".utf8), to: queuedProviderRequest)

        let stableWorkspaceBefore = try #require(try stableStore.load())
        let libraryBefore = try Data(contentsOf: workflowLibrary)
        let forkID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let outcome = try DesktopDevelopmentDataFork.prepare(
            environment: development,
            refresh: false,
            forkID: forkID,
            createdAtUnixMillis: 2_000
        )
        guard case let .created(receipt) = outcome else {
            Issue.record("Expected a newly created Development fork")
            return
        }

        #expect(receipt.forkID == forkID)
        #expect(receipt.authorityRemoved)
        #expect(!receipt.automaticExecutionEnabled)
        #expect(receipt.externalMutationPolicy == .denied)
        #expect(receipt.copiedWorkflowArtifactCount == 2)
        #expect(try stableStore.load() == stableWorkspaceBefore)
        #expect(try Data(contentsOf: workflowLibrary) == libraryBefore)

        let developmentStore = FileDesktopStateStore(fileURL: development.workspaceFileURL)
        let developmentModel = DesktopAppModel(store: developmentStore, now: { 3_000 })
        let copiedThread = try #require(developmentModel.thread(id: "thread-desktop-dogfood"))
        let copiedAutomation = try #require(
            developmentModel.snapshot.domains.automations.first { $0.id == automationID }
        )
        #expect(copiedThread.model == "Stable model")
        #expect(copiedThread.runtimeMode == .approvalRequired)
        #expect(!copiedThread.networkAccess)
        #expect(developmentModel.snapshot.preferences.safeMode)
        #expect(copiedAutomation.name == "Stable morning check")
        #expect(copiedAutomation.status == .paused)
        #expect(copiedAutomation.nextRunAtUnixMillis == nil)
        #expect(copiedAutomation.authority == .askEveryRun)
        #expect(developmentModel.snapshot.operations.workflows.capabilityInstallations.allSatisfy { !$0.enabled })
        #expect(FileManager.default.fileExists(atPath: development.applicationSupportRoot
            .appendingPathComponent("Workflows/workflow-library.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: development.applicationSupportRoot
            .appendingPathComponent("Objects/blobs/object.bin").path))
        #expect(!FileManager.default.fileExists(atPath: development.applicationSupportRoot
            .appendingPathComponent("ConversationService/thread/private-request.json").path))

        _ = developmentModel.createProject(name: "Dev only", path: nil, summary: "Independent mutation")
        #expect(try stableStore.load() == stableWorkspaceBefore)
        #expect(stableModel.snapshot.projects.allSatisfy { $0.name != "Dev only" })

        let second = try DesktopDevelopmentDataFork.prepare(
            environment: development,
            refresh: false,
            forkID: UUID(),
            createdAtUnixMillis: 4_000
        )
        guard case let .existing(existingReceipt) = second else {
            Issue.record("Expected the existing Development fork to be preserved")
            return
        }
        #expect(existingReceipt?.forkID == forkID)
        let reopened = DesktopAppModel(store: developmentStore, now: { 5_000 })
        #expect(reopened.snapshot.projects.contains { $0.name == "Dev only" })
    }

    @Test
    func explicitRefreshArchivesDevAndPreservesOnlyItsGoogleConfiguration() throws {
        let base = try TestTemporaryDirectory.make(prefix: "kaname-development-refresh")
        defer { try? FileManager.default.removeItem(at: base) }
        let stable = KanameDesktopEnvironment(channel: .stable, applicationSupportDirectory: base)
        let development = KanameDesktopEnvironment(channel: .development, applicationSupportDirectory: base)
        let stableModel = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: stable.workspaceFileURL),
            now: { 1_000 }
        )
        _ = stableModel.createProject(name: "Stable generation one", path: nil, summary: "First")
        let firstID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        _ = try DesktopDevelopmentDataFork.prepare(
            environment: development,
            refresh: false,
            forkID: firstID,
            createdAtUnixMillis: 2_000
        )

        let developmentModel = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: development.workspaceFileURL),
            now: { 3_000 }
        )
        _ = developmentModel.createProject(name: "Archived Dev work", path: nil, summary: "Recoverable")
        let accounts = development.googleDirectory.appendingPathComponent("accounts.json")
        let devOnly = development.applicationSupportRoot.appendingPathComponent("DevOnly/marker.txt")
        try write(Data(#"{"accounts":[]}"#.utf8), to: accounts)
        try write(Data("archive me".utf8), to: devOnly)
        _ = stableModel.createProject(name: "Stable generation two", path: nil, summary: "Second")
        let stableBytesBeforeRefresh = try Data(contentsOf: stable.workspaceFileURL)
        let refreshID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

        let outcome = try DesktopDevelopmentDataFork.prepare(
            environment: development,
            refresh: true,
            forkID: refreshID,
            createdAtUnixMillis: 4_000
        )
        guard case let .created(receipt) = outcome else {
            Issue.record("Expected an explicitly refreshed Development fork")
            return
        }

        #expect(receipt.previousDevelopmentDataArchived)
        #expect(receipt.forkID == refreshID)
        #expect(try Data(contentsOf: stable.workspaceFileURL) == stableBytesBeforeRefresh)
        #expect(try Data(contentsOf: accounts) == Data(#"{"accounts":[]}"#.utf8))
        #expect(!FileManager.default.fileExists(atPath: devOnly.path))

        let archive = base
            .appendingPathComponent("Kaname Dev Archives", isDirectory: true)
            .appendingPathComponent("fork-4000-\(refreshID.uuidString.lowercased())", isDirectory: true)
        #expect(try Data(contentsOf: archive.appendingPathComponent("DevOnly/marker.txt")) == Data("archive me".utf8))
        let refreshed = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: development.workspaceFileURL),
            now: { 5_000 }
        )
        #expect(refreshed.snapshot.projects.contains { $0.name == "Stable generation two" })
        #expect(!refreshed.snapshot.projects.contains { $0.name == "Archived Dev work" })
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}
