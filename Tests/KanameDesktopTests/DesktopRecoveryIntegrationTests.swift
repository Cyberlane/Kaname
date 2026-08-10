import Foundation
import Testing
@testable import KanameDesktop

@MainActor
struct DesktopRecoveryIntegrationTests {
    @Test
    func corruptFileIsPrivatelyQuarantinedAndCannotBeMutated() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspace.json")
        let corrupt = Data("private-corrupt-workspace".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try corrupt.write(to: file)
        let store = FileDesktopStateStore(fileURL: file)

        let model = DesktopAppModel(store: store, now: { 10_000 })

        #expect(model.isRecoveryReadOnly)
        #expect(model.recoveryStatus?.reason == .unreadableState)
        #expect(model.recoveryStatus?.quarantineCreated == true)
        #expect(try Data(contentsOf: file) == corrupt)
        let quarantineFiles = try regularFiles(below: store.quarantineDirectoryURL)
        let quarantinedWorkspace = try #require(quarantineFiles.first { $0.lastPathComponent == "workspace.json" })
        #expect(try Data(contentsOf: quarantinedWorkspace) == corrupt)
        #expect(mode(of: store.quarantineDirectoryURL) == 0o700)
        #expect(mode(of: quarantinedWorkspace) == 0o600)

        let projectCount = model.snapshot.projects.count
        _ = model.createProject(name: "Blocked", path: nil, summary: "Recovery")
        #expect(model.snapshot.projects.count == projectCount)
        #expect(try Data(contentsOf: file) == corrupt)

        _ = DesktopAppModel(store: store, now: { 11_000 })
        #expect(try regularFiles(below: store.quarantineDirectoryURL).filter { $0.lastPathComponent == "workspace.json" }.count == 1)
    }

    @Test
    func forwardVersionIsPreservedAndReportedWithoutDowngrade() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspace.json")
        let store = FileDesktopStateStore(fileURL: file)
        var future = DesktopAppSnapshot.starter(now: 1_000)
        future.version = DesktopAppSnapshot.currentVersion + 1
        let futureBytes = try JSONEncoder().encode(future)
        try store.save(futureBytes)

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(model.isRecoveryReadOnly)
        #expect(model.recoveryStatus?.reason == .unsupportedStateVersion)
        #expect(model.recoveryStatus?.detectedStateSchemaVersion == DesktopAppSnapshot.currentVersion + 1)
        #expect(try store.load() == futureBytes)
    }

    @Test
    func runtimeRecoveryMarkerPreventsMigrationWritesDuringStartup() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Desktop/workspace.json")
        let store = FileDesktopStateStore(fileURL: file)
        var legacy = DesktopAppSnapshot.starter(now: 1_000)
        legacy.version = 12
        legacy.threads[0].summary = "Preserve exact legacy bytes"
        let legacyBytes = try JSONEncoder().encode(legacy)
        try store.save(legacyBytes)
        try store.persistRecoveryLockMarker(DesktopRedactedDiagnosticEvent(
            category: "recovery",
            code: "fixture-runtime-rollback-unverified",
            occurredAtUnixMillis: 1_500
        ))

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(model.isRecoveryReadOnly)
        #expect(model.recoveryStatus?.reason == .runtimeRollbackUnverified)
        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(model.snapshot.threads[0].summary == "Preserve exact legacy bytes")
        #expect(try store.load() == legacyBytes)
        #expect(FileManager.default.fileExists(atPath: store.recoveryLockMarkerURL.path))
    }

    @Test
    func symbolicLinkStateIsRejectedWithoutCopyingItsTargetIntoRecovery() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside-private.txt")
        let file = root.appendingPathComponent("Desktop/workspace.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let privateBytes = Data("must-not-enter-recovery".utf8)
        try privateBytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        let store = FileDesktopStateStore(fileURL: file)

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(model.isRecoveryReadOnly)
        #expect(model.recoveryStatus?.reason == .unreadableState)
        #expect(model.recoveryStatus?.quarantineCreated == false)
        #expect(try Data(contentsOf: outside) == privateBytes)
        #expect(!FileManager.default.fileExists(atPath: store.quarantineDirectoryURL.path))
    }

    @Test
    func everySupportedMigrationPreservesUserOwnedThreadFields() throws {
        for version in 1..<DesktopAppSnapshot.currentVersion {
            var legacy = DesktopAppSnapshot.starter(now: 1_000)
            legacy.version = version
            let index = try #require(legacy.threads.firstIndex { $0.id == "thread-desktop-dogfood" })
            legacy.threads[index].summary = "User summary v\(version)"
            legacy.threads[index].attention = .completed
            legacy.threads[index].unread = false
            legacy.threads[index].updatedAtUnixMillis = 777
            legacy.threads[index].messages = [DesktopMessage(
                id: "user-message-v\(version)",
                role: .user,
                body: "User content v\(version)",
                createdAtUnixMillis: 700
            )]
            legacy.threads[index].plan = [DesktopPlanItem(title: "User plan", state: .inProgress)]
            legacy.threads[index].evidence = [DesktopEvidence(label: "User evidence", detail: "Exact", state: .notRun)]
            let store = RecoveryMemoryStore(primary: try JSONEncoder().encode(legacy), recovery: nil)

            let model = DesktopAppModel(store: store, now: { 2_000 })
            let migrated = try #require(model.thread(id: "thread-desktop-dogfood"))

            #expect(migrated.summary == "User summary v\(version)")
            #expect(migrated.attention == .completed)
            #expect(migrated.unread == false)
            #expect(migrated.updatedAtUnixMillis == 777)
            #expect(migrated.messages.map(\.body) == ["User content v\(version)"])
            #expect(migrated.plan.map(\.title) == ["User plan"])
            #expect(migrated.evidence.map(\.label) == ["User evidence"])
            #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        }
    }

    @Test
    func fileMigrationCreatesVerifiedPrivateBackupAndReceipt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspace.json")
        let store = FileDesktopStateStore(fileURL: file)
        var legacy = DesktopAppSnapshot.starter(now: 1_000)
        legacy.version = 12
        legacy.threads[0].summary = "Do not rewrite"
        try store.save(JSONEncoder().encode(legacy))

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(!model.isRecoveryReadOnly)
        #expect(model.thread(id: legacy.threads[0].id)?.summary == "Do not rewrite")
        let bundles = try FileManager.default.contentsOfDirectory(
            at: store.backupHistoryDirectoryURL,
            includingPropertiesForKeys: nil
        )
        let bundle = try #require(bundles.first)
        let manifest = try DesktopRecoveryService().validateBackup(at: bundle)
        #expect(manifest.stateSchemaVersion == 12)
        let backedUp = try DesktopRecoveryService().verifiedArtifactData(kind: .workspaceState, from: bundle)
        #expect(try JSONDecoder().decode(DesktopAppSnapshot.self, from: backedUp).version == 12)
        let receipts = try regularFiles(below: store.receiptDirectoryURL)
        let receiptURL = try #require(receipts.first { $0.lastPathComponent.hasPrefix("migration-") })
        let receipt = try JSONDecoder().decode(DesktopMigrationReceipt.self, from: Data(contentsOf: receiptURL))
        #expect(receipt.fromStateSchemaVersion == 12)
        #expect(receipt.toStateSchemaVersion == DesktopAppSnapshot.currentVersion)
        #expect(receipt.outcome == .applied)
        #expect(receipt.backupID == manifest.backupID)
        #expect(mode(of: bundle) == 0o700)
        #expect(mode(of: receiptURL) == 0o600)
    }

    @Test
    func verifiedBackupRestoreUnlocksModelAndResetPreparationDoesNotDeleteState() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Desktop/workspace.json")
        let store = FileDesktopStateStore(fileURL: file)
        try store.save(Data("corrupt".utf8))
        var restored = DesktopAppSnapshot.starter(now: 1_000)
        restored.threads[0].summary = "Verified restore target"
        let source = root.appendingPathComponent("restore-source.json")
        try JSONEncoder().encode(restored).write(to: source)
        let bundle = root.appendingPathComponent("explicit.kanamebackup")
        try DesktopRecoveryService().createBackup(
            at: bundle,
            sources: [.init(kind: .workspaceState, fileURL: source, archiveName: "workspace.json")],
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            createdAtUnixMillis: 1_500
        )
        let model = DesktopAppModel(store: store, now: { 2_000 })

        let reset = try model.prepareReset(verifiedBackupAt: bundle)
        #expect(model.isRecoveryReadOnly)
        #expect(try store.load() == Data("corrupt".utf8))
        #expect(reset.localArtifacts.count == 1)
        try model.restoreWorkspace(fromVerifiedBackup: bundle)

        #expect(!model.isRecoveryReadOnly)
        #expect(model.persistenceError == nil)
        #expect(model.snapshot.threads[0].summary == "Verified restore target")
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(FileManager.default.fileExists(atPath: store.quarantineDirectoryURL.path))
        let receipts = try regularFiles(below: store.receiptDirectoryURL)
        #expect(receipts.contains { $0.lastPathComponent.hasPrefix("reset-") })
        #expect(receipts.contains { $0.lastPathComponent.hasPrefix("restore-") })
    }

    @Test
    func resetRequiresVerifiedBackupAndPreservesItWithReceipt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Desktop/workspace.json")
        let store = FileDesktopStateStore(fileURL: file)
        try store.save(Data("corrupt".utf8))
        let model = DesktopAppModel(store: store, now: { 3_000 })
        #expect(model.isRecoveryReadOnly)

        let invalidBundle = root.appendingPathComponent("invalid.kanamebackup")
        try FileManager.default.createDirectory(at: invalidBundle, withIntermediateDirectories: true)
        #expect(throws: DesktopRecoveryError.self) {
            try model.resetWorkspace(verifiedBackupAt: invalidBundle)
        }
        #expect(model.isRecoveryReadOnly)
        #expect(try store.load() == Data("corrupt".utf8))

        let source = root.appendingPathComponent("reset-source.json")
        try Data("preserved-before-reset".utf8).write(to: source)
        let bundle = root.appendingPathComponent("reset.kanamebackup")
        let backup = try DesktopRecoveryService().createBackup(
            at: bundle,
            sources: [.init(kind: .workspaceState, fileURL: source, archiveName: "workspace.json")],
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            createdAtUnixMillis: 2_500
        )
        let journal = root.appendingPathComponent("LocalCore/journal/live-provider.sqlite")
        let pending = root.appendingPathComponent("ConversationService/Threads/thread-one/Inbox/run-one.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("durable-authority-journal".utf8).write(to: journal)
        try Data("queued-provider-request".utf8).write(to: pending)
        try store.persistRecoveryLockMarker(DesktopRedactedDiagnosticEvent(
            category: "recovery",
            code: "fixture-runtime-rollback-unverified",
            occurredAtUnixMillis: 2_750
        ))

        let reset = try model.resetWorkspace(verifiedBackupAt: bundle)

        #expect(!model.isRecoveryReadOnly)
        #expect(model.persistenceError == nil)
        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(model.snapshot.projects == DesktopAppSnapshot.starter(now: 3_000).projects)
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(try DesktopRecoveryService().validateBackup(at: bundle) == backup)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(!FileManager.default.fileExists(atPath: pending.path))
        #expect(!FileManager.default.fileExists(atPath: store.recoveryLockMarkerURL.path))
        #expect(reset.localArtifacts.contains { $0.kind == .localCoreJournal })
        #expect(reset.localArtifacts.contains { $0.kind == .conversationServiceState })
        let managedBackup = try #require(try regularFiles(below: store.backupHistoryDirectoryURL)
            .first { $0.lastPathComponent == DesktopRecoveryService.manifestFileName }
            .map { $0.deletingLastPathComponent() })
        let managedManifest = try DesktopRecoveryService().validateBackup(at: managedBackup)
        #expect(managedManifest.backupID == reset.verifiedBackupID)
        #expect(managedManifest.artifacts.contains {
            $0.kind == .localCoreJournal && $0.restoreRelativePath == "LocalCore/journal/live-provider.sqlite"
        })
        #expect(managedManifest.artifacts.contains {
            $0.kind == .conversationServiceState
                && $0.restoreRelativePath == "ConversationService/Threads/thread-one/Inbox/run-one.json"
        })
        let persisted = try #require(try store.load())
        #expect(try JSONDecoder().decode(DesktopAppSnapshot.self, from: persisted) == model.snapshot)
        let receipts = try regularFiles(below: store.receiptDirectoryURL)
        let resetReceipt = try #require(receipts.first { $0.lastPathComponent.hasPrefix("reset-") })
        #expect(try JSONDecoder().decode(DesktopResetManifest.self, from: Data(contentsOf: resetReceipt)) == reset)
    }

    @Test
    func resetRefusesWhileDurableProviderWorkerIsAlive() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Desktop/workspace.json")
        let store = FileDesktopStateStore(fileURL: file)
        try store.save(Data("corrupt".utf8))
        let model = DesktopAppModel(store: store, now: { 4_000 })
        #expect(model.isRecoveryReadOnly)

        let source = root.appendingPathComponent("reset-source.json")
        try Data("preserved-before-reset".utf8).write(to: source)
        let bundle = root.appendingPathComponent("reset.kanamebackup")
        _ = try DesktopRecoveryService().createBackup(
            at: bundle,
            sources: [.init(kind: .workspaceState, fileURL: source, archiveName: "workspace.json")],
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            createdAtUnixMillis: 3_500
        )
        let worker = root.appendingPathComponent("ConversationService/Threads/thread-one/worker.json")
        try FileManager.default.createDirectory(at: worker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"processIdentifier\":\(ProcessInfo.processInfo.processIdentifier)}".utf8).write(to: worker)

        #expect(throws: DesktopModelRecoveryError.activeRuntimeWork) {
            try model.resetWorkspace(verifiedBackupAt: bundle)
        }
        #expect(model.isRecoveryReadOnly)
        #expect(try store.load() == Data("corrupt".utf8))
        #expect(FileManager.default.fileExists(atPath: worker.path))
    }

    @Test
    func verifiedFullBackupRestoresWorkspaceAndRuntimeAsOneGeneration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Desktop/workspace.json")
        let store = FileDesktopStateStore(fileURL: file)
        try store.save(Data("corrupt".utf8))
        let currentJournal = root.appendingPathComponent("LocalCore/journal/live-provider.sqlite")
        let currentQueue = root.appendingPathComponent("ConversationService/Threads/old/Inbox/old.json")
        try FileManager.default.createDirectory(at: currentJournal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentQueue.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old-journal".utf8).write(to: currentJournal)
        try Data("old-queue".utf8).write(to: currentQueue)
        let model = DesktopAppModel(store: store, now: { 5_000 })
        #expect(model.isRecoveryReadOnly)

        let restoredSnapshot = DesktopAppSnapshot.starter(now: 4_000)
        let restoredWorkspace = root.appendingPathComponent("restore-workspace.json")
        let restoredJournal = root.appendingPathComponent("restore-journal.sqlite")
        let restoredQueue = root.appendingPathComponent("restore-queue.json")
        try JSONEncoder().encode(restoredSnapshot).write(to: restoredWorkspace)
        try Data("restored-journal".utf8).write(to: restoredJournal)
        try Data("restored-queue".utf8).write(to: restoredQueue)
        let bundle = root.appendingPathComponent("full.kanamebackup")
        _ = try DesktopRecoveryService().createBackup(
            at: bundle,
            sources: [
                .init(kind: .workspaceState, fileURL: restoredWorkspace, archiveName: "workspace.json"),
                .init(
                    kind: .localCoreJournal,
                    fileURL: restoredJournal,
                    archiveName: "journal.bin",
                    restoreRelativePath: "LocalCore/journal/live-provider.sqlite"
                ),
                .init(
                    kind: .conversationServiceState,
                    fileURL: restoredQueue,
                    archiveName: "queue.bin",
                    restoreRelativePath: "ConversationService/Threads/restored/Inbox/restored.json"
                ),
            ],
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            createdAtUnixMillis: 4_500,
            runtimeStateIncluded: true
        )
        try store.persistRecoveryLockMarker(DesktopRedactedDiagnosticEvent(
            category: "recovery",
            code: "fixture-runtime-rollback-unverified",
            occurredAtUnixMillis: 4_750
        ))

        try model.restoreWorkspace(fromVerifiedBackup: bundle)

        #expect(!model.isRecoveryReadOnly)
        #expect(!FileManager.default.fileExists(atPath: store.recoveryLockMarkerURL.path))
        #expect(model.snapshot == restoredSnapshot)
        #expect(try Data(contentsOf: currentJournal) == Data("restored-journal".utf8))
        #expect(!FileManager.default.fileExists(atPath: currentQueue.path))
        #expect(try Data(contentsOf: root.appendingPathComponent(
            "ConversationService/Threads/restored/Inbox/restored.json"
        )) == Data("restored-queue".utf8))
    }

    @Test
    func workspaceOnlyRestoreRefusesToMixWithCurrentRuntimeState() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Desktop/workspace.json")
        let store = FileDesktopStateStore(fileURL: file)
        try store.save(Data("corrupt".utf8))
        let currentJournal = root.appendingPathComponent("LocalCore/journal/live-provider.sqlite")
        try FileManager.default.createDirectory(at: currentJournal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("current-journal".utf8).write(to: currentJournal)
        let model = DesktopAppModel(store: store, now: { 6_000 })

        let workspace = root.appendingPathComponent("workspace-only.json")
        try JSONEncoder().encode(DesktopAppSnapshot.starter(now: 5_000)).write(to: workspace)
        let bundle = root.appendingPathComponent("workspace-only.kanamebackup")
        _ = try DesktopRecoveryService().createBackup(
            at: bundle,
            sources: [.init(kind: .workspaceState, fileURL: workspace, archiveName: "workspace.json")],
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            createdAtUnixMillis: 5_500
        )

        #expect(throws: DesktopModelRecoveryError.restoreArtifactInvalid) {
            try model.restoreWorkspace(fromVerifiedBackup: bundle)
        }
        #expect(model.isRecoveryReadOnly)
        #expect(try Data(contentsOf: currentJournal) == Data("current-journal".utf8))
    }

    @Test
    func secondRuntimeArchiveMoveFailureRestoresTheFirstRootBeforeReturning() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localCore = root.appendingPathComponent("LocalCore", isDirectory: true)
        let conversationService = root.appendingPathComponent("ConversationService", isDirectory: true)
        let journal = localCore.appendingPathComponent("journal/live.sqlite")
        let queue = conversationService.appendingPathComponent("Threads/thread/Inbox/run.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: queue.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original-journal".utf8).write(to: journal)
        try Data("original-queue".utf8).write(to: queue)
        let store = FileDesktopStateStore(
            fileURL: root.appendingPathComponent("Desktop/workspace.json")
        ) { source, destination in
            if source.standardizedFileURL == conversationService.standardizedFileURL {
                throw InjectedRuntimeMoveFailure.secondRoot
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }

        #expect(throws: InjectedRuntimeMoveFailure.self) {
            try store.archiveRuntimeState(
                resetID: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
            )
        }

        #expect(try Data(contentsOf: journal) == Data("original-journal".utf8))
        #expect(try Data(contentsOf: queue) == Data("original-queue".utf8))
    }

    @Test
    func secondRuntimeActivationMoveFailureRestoresBothOriginalRootsBeforeReturning() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localCore = root.appendingPathComponent("LocalCore", isDirectory: true)
        let conversationService = root.appendingPathComponent("ConversationService", isDirectory: true)
        let currentJournal = localCore.appendingPathComponent("journal/live.sqlite")
        let currentQueue = conversationService.appendingPathComponent("Threads/current/Inbox/run.json")
        try FileManager.default.createDirectory(at: currentJournal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentQueue.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("current-journal".utf8).write(to: currentJournal)
        try Data("current-queue".utf8).write(to: currentQueue)

        let restoredJournal = root.appendingPathComponent("fixture-restored-journal")
        let restoredQueue = root.appendingPathComponent("fixture-restored-queue")
        try Data("restored-journal".utf8).write(to: restoredJournal)
        try Data("restored-queue".utf8).write(to: restoredQueue)
        let bundle = root.appendingPathComponent("activation.kanamebackup")
        try DesktopRecoveryService().createBackup(
            at: bundle,
            sources: [
                .init(
                    kind: .localCoreJournal,
                    fileURL: restoredJournal,
                    archiveName: "journal.bin",
                    restoreRelativePath: "LocalCore/journal/live.sqlite"
                ),
                .init(
                    kind: .conversationServiceState,
                    fileURL: restoredQueue,
                    archiveName: "queue.bin",
                    restoreRelativePath: "ConversationService/Threads/restored/Inbox/run.json"
                ),
            ],
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            createdAtUnixMillis: 7_000,
            runtimeStateIncluded: true
        )
        let store = FileDesktopStateStore(
            fileURL: root.appendingPathComponent("Desktop/workspace.json")
        ) { source, destination in
            if source.path.contains("/RuntimeRestoreStaging/"),
               source.lastPathComponent == "ConversationService" {
                throw InjectedRuntimeMoveFailure.secondRoot
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }

        #expect(throws: InjectedRuntimeMoveFailure.self) {
            try store.activateVerifiedRuntimeRestore(
                from: bundle,
                restoreID: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!
            )
        }

        #expect(try Data(contentsOf: currentJournal) == Data("current-journal".utf8))
        #expect(try Data(contentsOf: currentQueue) == Data("current-queue".utf8))
    }

    @Test
    func unverifiedRuntimeActivationRollbackRemainsReadOnlyAfterRestart() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localCore = root.appendingPathComponent("LocalCore", isDirectory: true)
        let conversationService = root.appendingPathComponent("ConversationService", isDirectory: true)
        let currentJournal = localCore.appendingPathComponent("journal/live.sqlite")
        let currentQueue = conversationService.appendingPathComponent("Threads/current/Inbox/run.json")
        try FileManager.default.createDirectory(at: currentJournal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentQueue.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("current-journal".utf8).write(to: currentJournal)
        try Data("current-queue".utf8).write(to: currentQueue)

        let restoredWorkspace = root.appendingPathComponent("fixture-restored-workspace")
        let restoredJournal = root.appendingPathComponent("fixture-restored-journal")
        let restoredQueue = root.appendingPathComponent("fixture-restored-queue")
        try JSONEncoder().encode(DesktopAppSnapshot.starter(now: 9_000)).write(to: restoredWorkspace)
        try Data("restored-journal".utf8).write(to: restoredJournal)
        try Data("restored-queue".utf8).write(to: restoredQueue)
        let bundle = root.appendingPathComponent("activation-unverified.kanamebackup")
        try DesktopRecoveryService().createBackup(
            at: bundle,
            sources: [
                .init(kind: .workspaceState, fileURL: restoredWorkspace, archiveName: "workspace.json"),
                .init(
                    kind: .localCoreJournal,
                    fileURL: restoredJournal,
                    archiveName: "journal.bin",
                    restoreRelativePath: "LocalCore/journal/live.sqlite"
                ),
                .init(
                    kind: .conversationServiceState,
                    fileURL: restoredQueue,
                    archiveName: "queue.bin",
                    restoreRelativePath: "ConversationService/Threads/restored/Inbox/run.json"
                ),
            ],
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            createdAtUnixMillis: 9_500,
            runtimeStateIncluded: true
        )
        let store = FileDesktopStateStore(
            fileURL: root.appendingPathComponent("Desktop/workspace.json")
        ) { source, destination in
            if source.path.contains("/RuntimeRestoreStaging/"),
               source.lastPathComponent == "ConversationService" {
                throw InjectedRuntimeMoveFailure.secondRoot
            }
            if source.path.contains("/ResetArchives/"),
               destination.standardizedFileURL == localCore.standardizedFileURL {
                throw InjectedRuntimeMoveFailure.secondRoot
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        try store.save(Data("corrupt".utf8))
        let model = DesktopAppModel(store: store, now: { 10_000 })

        #expect(throws: DesktopModelRecoveryError.recoveryRollbackFailed) {
            try model.restoreWorkspace(fromVerifiedBackup: bundle)
        }
        #expect(model.recoveryStatus?.reason == .runtimeRollbackUnverified)
        #expect(FileManager.default.fileExists(atPath: store.recoveryLockMarkerURL.path))

        let restarted = DesktopAppModel(store: store, now: { 11_000 })
        #expect(restarted.isRecoveryReadOnly)
        #expect(restarted.recoveryStatus?.reason == .runtimeRollbackUnverified)
        let projectCount = restarted.snapshot.projects.count
        _ = restarted.createProject(name: "Must remain blocked", path: nil, summary: "Unsafe recovery")
        #expect(restarted.snapshot.projects.count == projectCount)
    }

    @Test
    func unverifiedSecondRootArchiveRollbackLocksTheModelReadOnly() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localCore = root.appendingPathComponent("LocalCore", isDirectory: true)
        let conversationService = root.appendingPathComponent("ConversationService", isDirectory: true)
        let journal = localCore.appendingPathComponent("journal/live.sqlite")
        let queue = conversationService.appendingPathComponent("Threads/thread/Inbox/run.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: queue.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original-journal".utf8).write(to: journal)
        try Data("original-queue".utf8).write(to: queue)
        let store = FileDesktopStateStore(
            fileURL: root.appendingPathComponent("Desktop/workspace.json")
        ) { source, destination in
            if source.standardizedFileURL == conversationService.standardizedFileURL
                || (source.path.contains("/ResetArchives/")
                    && destination.standardizedFileURL == localCore.standardizedFileURL) {
                throw InjectedRuntimeMoveFailure.secondRoot
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        try store.save(JSONEncoder().encode(DesktopAppSnapshot.starter(now: 8_000)))
        let model = DesktopAppModel(store: store, now: { 9_000 })
        let backupSource = root.appendingPathComponent("reset-source.json")
        try Data("verified-before-reset".utf8).write(to: backupSource)
        let backup = root.appendingPathComponent("reset.kanamebackup")
        try DesktopRecoveryService().createBackup(
            at: backup,
            sources: [.init(kind: .workspaceState, fileURL: backupSource, archiveName: "workspace.json")],
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            createdAtUnixMillis: 8_500
        )

        #expect(throws: DesktopModelRecoveryError.recoveryRollbackFailed) {
            try model.resetWorkspace(verifiedBackupAt: backup)
        }

        #expect(model.isRecoveryReadOnly)
        #expect(model.persistenceError == DesktopModelRecoveryError.recoveryRollbackFailed.localizedDescription)
        let originalProjectCount = model.snapshot.projects.count
        _ = model.createProject(name: "Must remain blocked", path: nil, summary: "Unsafe recovery")
        #expect(model.snapshot.projects.count == originalProjectCount)
        let events = try regularFiles(below: store.receiptDirectoryURL)
            .filter { $0.lastPathComponent.hasPrefix("failure-") }
            .map { try JSONDecoder().decode(DesktopRedactedDiagnosticEvent.self, from: Data(contentsOf: $0)) }
        #expect(events.contains { $0.code == "runtime-archive-rollback-unverified" })
        #expect(events.contains { $0.code == "reset-runtime-archive-rollback-unverified" })

        let restarted = DesktopAppModel(store: store, now: { 10_000 })
        #expect(restarted.isRecoveryReadOnly)
        #expect(restarted.recoveryStatus?.reason == .runtimeRollbackUnverified)
        #expect(restarted.persistenceError == DesktopModelRecoveryError.recoveryRollbackFailed.localizedDescription)
        let restartedProjectCount = restarted.snapshot.projects.count
        _ = restarted.createProject(name: "Restart must remain blocked", path: nil, summary: "Unsafe recovery")
        #expect(restarted.snapshot.projects.count == restartedProjectCount)
        let diagnostics = try JSONDecoder().decode(
            DesktopRedactedDiagnosticsBundle.self,
            from: Data(restarted.redactedSupportBundle().utf8)
        )
        #expect(diagnostics.events.contains { $0.code == "reset-runtime-archive-rollback-unverified" })
    }

    @Test
    func runtimeRecoveryLockRejectsSymlinksAndHardLinks() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        let runtime = root.appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let lock = runtime.appendingPathComponent("recovery-runtime.lock")
        let outside = root.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outside)
        #expect(throws: DesktopModelRecoveryError.activeRuntimeWork) {
            _ = try store.acquireExclusiveRuntimeRecoveryLock()
        }
        try FileManager.default.removeItem(at: lock)
        try Data().write(to: lock)
        try FileManager.default.linkItem(at: lock, to: root.appendingPathComponent("hard-link"))
        #expect(throws: DesktopModelRecoveryError.activeRuntimeWork) {
            _ = try store.acquireExclusiveRuntimeRecoveryLock()
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kaname-recovery-integration-\(UUID().uuidString)")
    }

    private func regularFiles(below directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        return try enumerator.compactMap { element -> URL? in
            let url = try #require(element as? URL)
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
    }

    private func mode(of url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.posixPermissions] as? NSNumber else { return -1 }
        return value.intValue
    }
}

private enum InjectedRuntimeMoveFailure: Error {
    case secondRoot
}

private final class RecoveryMemoryStore: DesktopRecoveryStateStoring {
    var primary: Data?
    var recovery: Data?

    init(primary: Data?, recovery: Data?) {
        self.primary = primary
        self.recovery = recovery
    }

    func load() -> Data? { primary }
    func save(_ data: Data) { primary = data }
    func loadRecovery() -> Data? { recovery }
    func saveRecovered(_ data: Data) { primary = data }
}
