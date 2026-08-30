import Foundation
import Testing
@testable import KanameDesktop

struct DesktopAutomaticBackupTests {
    @Test
    func pbkdf2MatchesPublishedSHA256Vector() throws {
        let key = try PBKDF2SHA256.deriveKey(
            password: Data("password".utf8),
            salt: Data("salt".utf8),
            rounds: 1,
            outputByteCount: 32
        )
        #expect(hex(key) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    @Test
    func encryptedBackupBundleRoundTripsAndDetectsWrongPassphrase() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace.json")
        try Data("workspace-state".utf8).write(to: workspace)
        let bundle = root.appendingPathComponent("source.kanamebackup", isDirectory: true)
        let backupID = UUID()
        _ = try DesktopRecoveryService().createBackup(
            at: bundle,
            sources: [.init(kind: .workspaceState, fileURL: workspace, archiveName: "workspace.json")],
            stateSchemaVersion: 17,
            backupID: backupID,
            createdAtUnixMillis: 1_234
        )
        let artifact = try DesktopEncryptedBackupBundleCodec.seal(
            bundleURL: bundle,
            passphrase: "a strong local backup passphrase"
        )
        #expect(artifact.backupID == backupID)
        #expect(artifact.sha256 == DesktopRecoveryService.sha256(artifact.data))
        let restored = root.appendingPathComponent("restored.kanamebackup", isDirectory: true)
        let manifest = try DesktopEncryptedBackupBundleCodec.open(
            artifact.data,
            passphrase: "a strong local backup passphrase",
            destination: restored
        )
        #expect(manifest.backupID == backupID)
        #expect(try DesktopRecoveryService().validateBackup(at: restored) == manifest)
        #expect(throws: DesktopWorkflowTransferError.invalidPassphrase) {
            try DesktopEncryptedBackupBundleCodec.open(
                artifact.data,
                passphrase: "the wrong backup passphrase",
                destination: root.appendingPathComponent("wrong.kanamebackup")
            )
        }
    }

    @Test
    func deterministicLargeStateDrillVerifiesStagesAndRollsBackInjectedFailure() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let components = largeFixtureComponents()
        let firstSources = try writeFixture(components, below: root.appendingPathComponent("fixture-a"))
        let secondSources = try writeFixture(components.reversed(), below: root.appendingPathComponent("fixture-b"))
        let firstBundle = root.appendingPathComponent("first.kanamebackup", isDirectory: true)
        let secondBundle = root.appendingPathComponent("second.kanamebackup", isDirectory: true)
        let backupID = UUID(uuidString: "00000000-0000-0000-0000-000000000951")!
        let restoreID = UUID(uuidString: "00000000-0000-0000-0000-000000000952")!
        let service = DesktopRecoveryService()

        let firstManifest = try service.createBackup(
            at: firstBundle,
            sources: firstSources,
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            backupID: backupID,
            createdAtUnixMillis: 1_800_000_000_000,
            runtimeStateIncluded: true
        )
        let secondManifest = try service.createBackup(
            at: secondBundle,
            sources: secondSources,
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            backupID: backupID,
            createdAtUnixMillis: 1_800_000_000_000,
            runtimeStateIncluded: true
        )

        #expect(firstManifest == secondManifest)
        #expect(firstManifest.artifacts.count == components.count)
        #expect(firstManifest.artifacts.reduce(Int64(0)) { $0 + $1.byteCount } > 8 * 1_024 * 1_024)
        #expect(
            try Data(contentsOf: firstBundle.appendingPathComponent(DesktopRecoveryService.manifestFileName))
                == Data(contentsOf: secondBundle.appendingPathComponent(DesktopRecoveryService.manifestFileName))
        )
        for artifact in firstManifest.artifacts {
            #expect(
                try Data(contentsOf: firstBundle.appendingPathComponent(artifact.relativePath))
                    == Data(contentsOf: secondBundle.appendingPathComponent(artifact.relativePath))
            )
        }

        let plan = try DesktopBackupRestorePlanner.plan(
            forVerifiedBundleAt: firstBundle,
            currentStateSchemaVersion: DesktopAppSnapshot.currentVersion
        )
        let repeatedPlan = try DesktopBackupRestorePlanner.plan(
            forVerifiedBundleAt: firstBundle,
            currentStateSchemaVersion: DesktopAppSnapshot.currentVersion
        )
        #expect(plan == repeatedPlan)
        #expect(plan.backupID == backupID)
        #expect(plan.action == .restoreCurrentSchema)
        #expect(plan.canRestore)
        #expect(!plan.requiresMigration)
        #expect(plan.artifactCount == components.count)
        #expect(plan.verifiedByteCount == firstManifest.artifacts.reduce(Int64(0)) { $0 + $1.byteCount })
        #expect(plan.manifestSHA256 == DesktopRecoveryService.sha256(
            try Data(contentsOf: firstBundle.appendingPathComponent(DesktopRecoveryService.manifestFileName))
        ))

        let passphrase = "deterministic synthetic drill passphrase"
        let encrypted = try DesktopEncryptedBackupBundleCodec.seal(
            bundleURL: firstBundle,
            passphrase: passphrase
        )
        let decryptedBundle = root.appendingPathComponent("decrypted.kanamebackup", isDirectory: true)
        let encryptedPlanningResult = try DesktopSyntheticBackupRestoreDrill.planEncryptedBackup(
            encrypted.data,
            passphrase: passphrase,
            verifiedBundleDestination: decryptedBundle,
            currentStateSchemaVersion: DesktopAppSnapshot.currentVersion
        )
        let decryptedPlan = try #require(encryptedPlanningResult.plan)
        #expect(decryptedPlan == plan)
        #expect(try service.validateBackup(at: decryptedBundle) == firstManifest)

        let stagedRestore = root.appendingPathComponent("restore-staging", isDirectory: true)
        let receipt = try DesktopSyntheticBackupRestoreDrill.stageRestore(
            using: decryptedPlan,
            from: decryptedBundle,
            at: stagedRestore,
            snapshotRoot: root.appendingPathComponent("stage-snapshot"),
            restoreID: restoreID,
            stagedAtUnixMillis: 1_800_000_001_000
        )
        #expect(receipt.backupID == backupID)
        #expect(receipt.verifiedArtifactCount == components.count)
        #expect(receipt.verifiedByteCount == plan.verifiedByteCount)
        for artifact in firstManifest.artifacts {
            #expect(
                try Data(contentsOf: stagedRestore.appendingPathComponent(artifact.relativePath))
                    == Data(contentsOf: firstBundle.appendingPathComponent(artifact.relativePath))
            )
        }

        let corruptManifestBundle = root.appendingPathComponent("corrupt-manifest.kanamebackup")
        try FileManager.default.copyItem(at: firstBundle, to: corruptManifestBundle)
        try Data("{".utf8).write(
            to: corruptManifestBundle.appendingPathComponent(DesktopRecoveryService.manifestFileName),
            options: .atomic
        )
        let corruptManifestStaging = root.appendingPathComponent("corrupt-manifest-staging")
        #expect(throws: DecodingError.self) {
            try DesktopSyntheticBackupRestoreDrill.stageRestore(
                using: plan,
                from: corruptManifestBundle,
                at: corruptManifestStaging,
                snapshotRoot: root.appendingPathComponent("corrupt-manifest-snapshot"),
                stagedAtUnixMillis: 1_800_000_002_000
            )
        }
        #expect(!FileManager.default.fileExists(atPath: corruptManifestStaging.path))

        let missingComponentBundle = root.appendingPathComponent("missing-component.kanamebackup")
        try FileManager.default.copyItem(at: firstBundle, to: missingComponentBundle)
        let missingArtifact = try #require(firstManifest.artifacts.first)
        try FileManager.default.removeItem(at: missingComponentBundle.appendingPathComponent(missingArtifact.relativePath))
        let missingComponentStaging = root.appendingPathComponent("missing-component-staging")
        #expect(throws: DesktopRecoveryError.missingArtifact) {
            try DesktopSyntheticBackupRestoreDrill.stageRestore(
                using: plan,
                from: missingComponentBundle,
                at: missingComponentStaging,
                snapshotRoot: root.appendingPathComponent("missing-component-snapshot"),
                stagedAtUnixMillis: 1_800_000_003_000
            )
        }
        #expect(!FileManager.default.fileExists(atPath: missingComponentStaging.path))

        let envelope = try JSONDecoder().decode(DesktopEncryptedTransferEnvelope.self, from: encrypted.data)
        var corruptSealedData = envelope.sealedData
        let firstCiphertextIndex = try #require(corruptSealedData.indices.first)
        corruptSealedData[firstCiphertextIndex] ^= 0x01
        let corruptObject = try JSONEncoder().encode(DesktopEncryptedTransferEnvelope(
            kind: envelope.kind,
            salt: envelope.salt,
            sealedData: corruptSealedData
        ))
        let corruptObjectDestination = root.appendingPathComponent("corrupt-object.kanamebackup")
        #expect(throws: DesktopWorkflowTransferError.invalidPassphrase) {
            try DesktopSyntheticBackupRestoreDrill.planEncryptedBackup(
                corruptObject,
                passphrase: passphrase,
                verifiedBundleDestination: corruptObjectDestination,
                currentStateSchemaVersion: DesktopAppSnapshot.currentVersion
            )
        }
        #expect(!FileManager.default.fileExists(atPath: corruptObjectDestination.path))

        let activeRoot = root.appendingPathComponent("synthetic-active", isDirectory: true)
        let currentJournal = activeRoot.appendingPathComponent("LocalCore/journal/live.sqlite")
        let currentQueue = activeRoot.appendingPathComponent("ConversationService/Threads/current/Inbox/run.json")
        try FileManager.default.createDirectory(
            at: currentJournal.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: currentQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("current-journal".utf8).write(to: currentJournal)
        try Data("current-queue".utf8).write(to: currentQueue)
        var injectedFailureObserved = false
        let store = FileDesktopStateStore(
            fileURL: activeRoot.appendingPathComponent("Desktop/workspace.json")
        ) { source, destination in
            if source.path.contains("/RuntimeRestoreStaging/"),
               source.lastPathComponent == "ConversationService" {
                injectedFailureObserved = true
                throw BackupDrillInjectedFailure.activation
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }

        #expect(throws: BackupDrillInjectedFailure.activation) {
            try DesktopSyntheticBackupRestoreDrill.activateRuntimeRestore(
                using: decryptedPlan,
                from: decryptedBundle,
                store: store,
                snapshotRoot: root.appendingPathComponent("activation-snapshot"),
                restoreID: restoreID
            )
        }
        #expect(injectedFailureObserved)
        #expect(try Data(contentsOf: currentJournal) == Data("current-journal".utf8))
        #expect(try Data(contentsOf: currentQueue) == Data("current-queue".utf8))
        #expect(!FileManager.default.fileExists(atPath: activeRoot.appendingPathComponent(
            "ConversationService/Threads/restored/Inbox/run.json"
        ).path))
        let failedJournal = store.managedRecoveryDirectoryURL
            .appendingPathComponent(
                "FailedRuntimeRestores/" + restoreID.uuidString.lowercased() + "/LocalCore/journal/live.sqlite"
            )
        let restoredJournalComponent = try #require(components.first { $0.kind == .localCoreJournal })
        #expect(try Data(contentsOf: failedJournal) == restoredJournalComponent.data)
        #expect(try service.validateBackup(at: decryptedBundle) == firstManifest)
    }

    @Test
    func planBoundSnapshotPreventsSourceReplacementAndAlwaysCleansUp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plannedData = Data("originally-planned-runtime-bytes".utf8)
        let replacementData = Data("valid-but-unplanned-runtime-bytes".utf8)
        let plannedSource = root.appendingPathComponent("planned-source.bin")
        let replacementSource = root.appendingPathComponent("replacement-source.bin")
        try plannedData.write(to: plannedSource)
        try replacementData.write(to: replacementSource)

        let plannedMaster = root.appendingPathComponent("planned-master.kanamebackup")
        let replacement = root.appendingPathComponent("replacement.kanamebackup")
        let service = DesktopRecoveryService()
        let plannedManifest = try service.createBackup(
            at: plannedMaster,
            sources: [.init(
                kind: .localCoreJournal,
                fileURL: plannedSource,
                archiveName: "local-core.bin",
                restoreRelativePath: "LocalCore/journal/live.sqlite"
            )],
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000972")!,
            createdAtUnixMillis: 100,
            runtimeStateIncluded: true
        )
        _ = try service.createBackup(
            at: replacement,
            sources: [.init(
                kind: .localCoreJournal,
                fileURL: replacementSource,
                archiveName: "local-core.bin",
                restoreRelativePath: "LocalCore/journal/live.sqlite"
            )],
            stateSchemaVersion: DesktopAppSnapshot.currentVersion,
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000973")!,
            createdAtUnixMillis: 101,
            runtimeStateIncluded: true
        )

        let stageCaller = root.appendingPathComponent("stage-caller.kanamebackup")
        try FileManager.default.copyItem(at: plannedMaster, to: stageCaller)
        let stagePlan = try DesktopBackupRestorePlanner.plan(
            forVerifiedBundleAt: stageCaller,
            currentStateSchemaVersion: DesktopAppSnapshot.currentVersion
        )
        let stageOutput = root.appendingPathComponent("race-stage-output")
        let stageSnapshot = root.appendingPathComponent("race-stage-snapshot")
        _ = try DesktopSyntheticBackupRestoreDrill.stageRestore(
            using: stagePlan,
            from: stageCaller,
            at: stageOutput,
            snapshotRoot: stageSnapshot,
            stagedAtUnixMillis: 102
        ) {
            try FileManager.default.removeItem(at: stageCaller)
            try FileManager.default.copyItem(at: replacement, to: stageCaller)
        }
        let plannedArtifact = try #require(plannedManifest.artifacts.first)
        #expect(try Data(contentsOf: stageOutput.appendingPathComponent(plannedArtifact.relativePath)) == plannedData)
        #expect(!FileManager.default.fileExists(atPath: stageSnapshot.path))
        #expect(try service.validateBackup(at: stageCaller).backupID
            == UUID(uuidString: "00000000-0000-0000-0000-000000000973")!)

        let activationCaller = root.appendingPathComponent("activation-caller.kanamebackup")
        try FileManager.default.copyItem(at: plannedMaster, to: activationCaller)
        let activationPlan = try DesktopBackupRestorePlanner.plan(
            forVerifiedBundleAt: activationCaller,
            currentStateSchemaVersion: DesktopAppSnapshot.currentVersion
        )
        let activeRoot = root.appendingPathComponent("race-active")
        let store = FileDesktopStateStore(fileURL: activeRoot.appendingPathComponent("Desktop/workspace.json"))
        let activationSnapshot = root.appendingPathComponent("race-activation-snapshot")
        _ = try DesktopSyntheticBackupRestoreDrill.activateRuntimeRestore(
            using: activationPlan,
            from: activationCaller,
            store: store,
            snapshotRoot: activationSnapshot,
            restoreID: UUID(uuidString: "00000000-0000-0000-0000-000000000974")!
        ) {
            try FileManager.default.removeItem(at: activationCaller)
            try FileManager.default.copyItem(at: replacement, to: activationCaller)
        }
        #expect(try Data(contentsOf: activeRoot.appendingPathComponent("LocalCore/journal/live.sqlite"))
            == plannedData)
        #expect(!FileManager.default.fileExists(atPath: activationSnapshot.path))

        let corruptCaller = root.appendingPathComponent("corrupt-caller.kanamebackup")
        try FileManager.default.copyItem(at: plannedMaster, to: corruptCaller)
        try Data("{".utf8).write(
            to: corruptCaller.appendingPathComponent(DesktopRecoveryService.manifestFileName),
            options: .atomic
        )
        let failureSnapshot = root.appendingPathComponent("failure-snapshot")
        let failureOutput = root.appendingPathComponent("failure-output")
        #expect(throws: DecodingError.self) {
            try DesktopSyntheticBackupRestoreDrill.stageRestore(
                using: stagePlan,
                from: corruptCaller,
                at: failureOutput,
                snapshotRoot: failureSnapshot,
                stagedAtUnixMillis: 103
            )
        }
        #expect(!FileManager.default.fileExists(atPath: failureSnapshot.path))
        #expect(!FileManager.default.fileExists(atPath: failureOutput.path))

        #expect(throws: DesktopAutomaticBackupError.unsafeBundle) {
            try DesktopSyntheticBackupRestoreDrill.stageRestore(
                using: stagePlan,
                from: plannedMaster,
                at: root.appendingPathComponent("escape-output"),
                snapshotRoot: plannedMaster.appendingPathComponent("nested-snapshot"),
                stagedAtUnixMillis: 104
            )
        }
    }

    @Test
    func restorePlanClassifiesCrossSchemaGenerationsDeterministically() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("workspace.json")
        try Data("synthetic-workspace".utf8).write(to: source)
        let current = DesktopAppSnapshot.currentVersion
        #expect(current > 1)
        let cases: [(Int, DesktopBackupRestoreAction)] = [
            (current, .restoreCurrentSchema),
            (current - 1, .migrateThenRestore),
            (current + 1, .rejectUnsupportedNewerSchema),
            (0, .rejectUnsupportedOlderSchema),
        ]

        var plans: [DesktopBackupRestorePlan] = []
        var bundles: [URL] = []
        for (index, entry) in cases.enumerated() {
            let bundle = root.appendingPathComponent("schema-\(index).kanamebackup")
            try DesktopRecoveryService().createBackup(
                at: bundle,
                sources: [.init(kind: .workspaceState, fileURL: source, archiveName: "workspace.json")],
                stateSchemaVersion: entry.0,
                backupID: UUID(uuidString: "00000000-0000-0000-0000-00000000096\(index)")!,
                createdAtUnixMillis: Int64(index + 1)
            )
            let plan = try DesktopBackupRestorePlanner.plan(
                forVerifiedBundleAt: bundle,
                currentStateSchemaVersion: current
            )
            let repeatedPlan = try DesktopBackupRestorePlanner.plan(
                forVerifiedBundleAt: bundle,
                currentStateSchemaVersion: current
            )
            #expect(plan == repeatedPlan)
            #expect(plan.action == entry.1)
            #expect(plan.backupStateSchemaVersion == entry.0)
            #expect(plan.targetStateSchemaVersion == current)
            #expect(plan.canRestore == (entry.1 == .restoreCurrentSchema || entry.1 == .migrateThenRestore))
            #expect(plan.requiresMigration == (entry.1 == .migrateThenRestore))
            plans.append(plan)
            bundles.append(bundle)

            if !plan.canRestore {
                let staging = root.appendingPathComponent("unsupported-\(index)-staging")
                #expect(throws: DesktopAutomaticBackupError.unsupportedRestoreSchema) {
                    try DesktopSyntheticBackupRestoreDrill.stageRestore(
                        using: plan,
                        from: bundle,
                        at: staging,
                        snapshotRoot: root.appendingPathComponent("unsupported-\(index)-snapshot"),
                        stagedAtUnixMillis: Int64(index + 10)
                    )
                }
                #expect(!FileManager.default.fileExists(atPath: staging.path))
            }
        }

        let unsupportedActivationRoot = root.appendingPathComponent("unsupported-activation")
        let unsupportedStore = FileDesktopStateStore(
            fileURL: unsupportedActivationRoot.appendingPathComponent("Desktop/workspace.json")
        )
        #expect(throws: DesktopAutomaticBackupError.unsupportedRestoreSchema) {
            try DesktopSyntheticBackupRestoreDrill.activateRuntimeRestore(
                using: plans[2],
                from: bundles[2],
                store: unsupportedStore,
                snapshotRoot: root.appendingPathComponent("unsupported-activation-snapshot"),
                restoreID: UUID(uuidString: "00000000-0000-0000-0000-000000000970")!
            )
        }
        #expect(!FileManager.default.fileExists(atPath: unsupportedActivationRoot.path))

        let staleBundle = root.appendingPathComponent("stale-plan.kanamebackup")
        try FileManager.default.copyItem(at: bundles[0], to: staleBundle)
        let stalePlan = try DesktopBackupRestorePlanner.plan(
            forVerifiedBundleAt: staleBundle,
            currentStateSchemaVersion: current
        )
        let staleManifestURL = staleBundle.appendingPathComponent(DesktopRecoveryService.manifestFileName)
        var staleManifestObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: staleManifestURL)) as? [String: Any]
        )
        staleManifestObject["createdAtUnixMillis"] = 9_999
        try JSONSerialization.data(withJSONObject: staleManifestObject, options: [.prettyPrinted, .sortedKeys])
            .write(to: staleManifestURL, options: .atomic)
        #expect(try DesktopRecoveryService().validateBackup(at: staleBundle).createdAtUnixMillis == 9_999)

        let staleStaging = root.appendingPathComponent("stale-plan-staging")
        #expect(throws: DesktopAutomaticBackupError.staleRestorePlan) {
            try DesktopSyntheticBackupRestoreDrill.stageRestore(
                using: stalePlan,
                from: staleBundle,
                at: staleStaging,
                snapshotRoot: root.appendingPathComponent("stale-stage-snapshot"),
                stagedAtUnixMillis: 20
            )
        }
        #expect(!FileManager.default.fileExists(atPath: staleStaging.path))

        let staleActivationRoot = root.appendingPathComponent("stale-plan-activation")
        let staleStore = FileDesktopStateStore(
            fileURL: staleActivationRoot.appendingPathComponent("Desktop/workspace.json")
        )
        #expect(throws: DesktopAutomaticBackupError.staleRestorePlan) {
            try DesktopSyntheticBackupRestoreDrill.activateRuntimeRestore(
                using: stalePlan,
                from: staleBundle,
                store: staleStore,
                snapshotRoot: root.appendingPathComponent("stale-activation-snapshot"),
                restoreID: UUID(uuidString: "00000000-0000-0000-0000-000000000971")!
            )
        }
        #expect(!FileManager.default.fileExists(atPath: staleActivationRoot.path))

        #expect(throws: DesktopAutomaticBackupError.invalidConfiguration) {
            try DesktopBackupRestorePlanner.plan(
                forVerifiedBundleAt: root.appendingPathComponent("schema-0.kanamebackup"),
                currentStateSchemaVersion: current,
                oldestMigratableStateSchemaVersion: current + 1
            )
        }
    }

    @Test
    func missingPassphraseIsAnExplicitTerminalStateWithoutDestinationWrites() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("must-not-exist.kanamebackup")

        let result = try DesktopSyntheticBackupRestoreDrill.planEncryptedBackup(
            Data("synthetic encrypted object".utf8),
            passphrase: nil,
            verifiedBundleDestination: destination,
            currentStateSchemaVersion: DesktopAppSnapshot.currentVersion
        )
        #expect(result == .terminal(.passphraseUnavailable))
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        let emptyDestination = root.appendingPathComponent("empty-must-not-exist.kanamebackup")
        let emptyResult = try DesktopSyntheticBackupRestoreDrill.planEncryptedBackup(
            Data("synthetic encrypted object".utf8),
            passphrase: "",
            verifiedBundleDestination: emptyDestination,
            currentStateSchemaVersion: DesktopAppSnapshot.currentVersion
        )
        #expect(emptyResult == .terminal(.passphraseUnavailable))
        #expect(!FileManager.default.fileExists(atPath: emptyDestination.path))
    }

    @Test
    func localTransportVerifiesListsDownloadsAndDeletesGenerations() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocalFolderDesktopBackupTransport(root: root)
        let data = Data("encrypted-generation".utf8)
        let digest = DesktopRecoveryService.sha256(data)
        let key = "kaname-backups/generations/1-test.kanamebackup.encrypted"
        try await transport.testConnection(prefix: "kaname-backups")
        try await transport.put(key: key, data: data, sha256: digest)
        #expect(try await transport.get(key: key) == data)
        let objects = try await transport.list(prefix: "kaname-backups")
        #expect(objects.map(\.key) == [key])
        try await transport.delete(key: key)
        #expect(try await transport.list(prefix: "kaname-backups").isEmpty)
    }

    @Test
    func retentionNeverRemovesTheThreeNewestGenerations() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocalFolderDesktopBackupTransport(root: root)
        var configuration = DesktopAutomaticBackupConfiguration()
        configuration.localFolderPath = root.path
        configuration.retentionDays = 7
        let now = Date(timeIntervalSince1970: 2_000_000)
        for index in 0..<5 {
            let key = "kaname-backups/generations/\(index).kanamebackup.encrypted"
            let data = Data("generation-\(index)".utf8)
            try await transport.put(key: key, data: data, sha256: DesktopRecoveryService.sha256(data))
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(Double(index - 10) * 86_400)],
                ofItemAtPath: root.appendingPathComponent(key).path
            )
        }

        try await DesktopAutomaticBackupService().enforceRetention(
            transport: transport,
            configuration: configuration,
            now: now
        )

        #expect(try await transport.list(prefix: configuration.prefix).map(\.key) == [
            "kaname-backups/generations/2.kanamebackup.encrypted",
            "kaname-backups/generations/3.kanamebackup.encrypted",
            "kaname-backups/generations/4.kanamebackup.encrypted",
        ])
    }

    @Test
    func configurationIsOptInAndRemoteDestinationRequiresHTTPS() throws {
        let defaults = DesktopAutomaticBackupConfiguration()
        #expect(defaults.enabled == false)
        #expect(throws: DesktopAutomaticBackupError.invalidConfiguration) { try defaults.validated() }
        var remote = defaults
        remote.destination = .cloudflareR2
        remote.endpoint = "http://example.r2.cloudflarestorage.com"
        remote.bucket = "kaname-backups"
        #expect(throws: DesktopAutomaticBackupError.invalidConfiguration) { try remote.validated() }
        remote.endpoint = "https://example.r2.cloudflarestorage.com"
        #expect(try remote.validated().region == "auto")
    }

    @Test
    func s3SignerUsesR2PathStyleRegionAndSignedIntegrityMetadata() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = S3DesktopBackupTransport(
            endpoint: URL(string: "https://example.r2.cloudflarestorage.com")!,
            bucket: "kaname-backups",
            region: "auto",
            accessKeyID: "ACCESSKEY",
            secretAccessKey: "secret",
            now: { date }
        )
        let body = Data("ciphertext".utf8)
        let digest = DesktopRecoveryService.sha256(body)
        let request = try transport.signedRequest(
            method: "PUT",
            key: "kaname/generations/example.encrypted",
            queryItems: [],
            body: body,
            metadataSHA256: digest
        )
        #expect(request.url?.absoluteString == "https://example.r2.cloudflarestorage.com/kaname-backups/kaname/generations/example.encrypted")
        #expect(request.value(forHTTPHeaderField: "x-amz-meta-kaname-sha256") == digest)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("/auto/s3/aws4_request") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-meta-kaname-sha256") == true)
    }

    @Test
    func s3ListParserPreservesContinuationForCompleteRetentionScans() throws {
        let xml = Data("""
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <Contents>
            <Key>kaname-backups/generations/1.encrypted</Key>
            <LastModified>2026-08-12T01:02:03Z</LastModified>
            <Size>42</Size>
          </Contents>
          <NextContinuationToken>opaque+/token==</NextContinuationToken>
        </ListBucketResult>
        """.utf8)
        let parser = S3ListObjectsParser(data: xml)

        #expect(parser.parse())
        #expect(parser.isTruncated)
        #expect(parser.nextContinuationToken == "opaque+/token==")
        #expect(parser.objects.map(\.key) == ["kaname-backups/generations/1.encrypted"])
        #expect(parser.objects.first?.byteCount == 42)
    }

    private func temporaryDirectory() throws -> URL {
        try TestTemporaryDirectory.make(prefix: "kaname-backup-tests")
    }

    private func largeFixtureComponents() -> [BackupDrillComponent] {
        let mebibyte = 1_024 * 1_024
        return [
            .init(
                kind: .workspaceState,
                archiveName: "workspace.json",
                restoreRelativePath: nil,
                data: Data(repeating: 0x01, count: 64 * 1_024)
            ),
            .init(
                kind: .previousWorkspaceState,
                archiveName: "workspace.previous.json",
                restoreRelativePath: nil,
                data: Data(repeating: 0x02, count: 64 * 1_024)
            ),
            .init(
                kind: .localCoreJournal,
                archiveName: "local-core-journal.bin",
                restoreRelativePath: "LocalCore/journal/live.sqlite",
                data: Data(repeating: 0x03, count: 2 * mebibyte)
            ),
            .init(
                kind: .localCoreSnapshot,
                archiveName: "local-core-snapshot.bin",
                restoreRelativePath: "LocalCore/snapshots/state.bin",
                data: Data(repeating: 0x04, count: 2 * mebibyte)
            ),
            .init(
                kind: .conversationServiceState,
                archiveName: "conversation-state.bin",
                restoreRelativePath: "ConversationService/Threads/restored/Inbox/run.json",
                data: Data(repeating: 0x05, count: 2 * mebibyte)
            ),
            .init(
                kind: .workflowInstallationState,
                archiveName: "workflow-installation.bin",
                restoreRelativePath: "WorkflowInstallations/example/Artifacts/output.bin",
                data: Data(repeating: 0x06, count: mebibyte)
            ),
            .init(
                kind: .workflowCapabilityPackage,
                archiveName: "workflow-capability.bin",
                restoreRelativePath: "WorkflowCapabilities/org.example.capability/package.bin",
                data: Data(repeating: 0x07, count: 512 * 1_024)
            ),
            .init(
                kind: .workflowLibraryState,
                archiveName: "workflow-library.bin",
                restoreRelativePath: "Workflows/org.example.workflow/state.json",
                data: Data(repeating: 0x08, count: 512 * 1_024)
            ),
            .init(
                kind: .workflowObjectState,
                archiveName: "workflow-object.bin",
                restoreRelativePath: "Objects/object-1/blob.bin",
                data: Data(repeating: 0x09, count: mebibyte)
            ),
        ]
    }

    private func writeFixture<S: Sequence>(
        _ components: S,
        below root: URL
    ) throws -> [DesktopRecoverySource] where S.Element == BackupDrillComponent {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try components.map { component in
            let source = root.appendingPathComponent(component.archiveName)
            try component.data.write(to: source)
            return DesktopRecoverySource(
                kind: component.kind,
                fileURL: source,
                archiveName: component.archiveName,
                restoreRelativePath: component.restoreRelativePath
            )
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private struct BackupDrillComponent {
    let kind: DesktopRecoveryArtifactKind
    let archiveName: String
    let restoreRelativePath: String?
    let data: Data
}

private enum BackupDrillInjectedFailure: Error {
    case activation
}
