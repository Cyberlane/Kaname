import Foundation
import Testing
@testable import KanameDesktop

struct DesktopRecoveryFoundationTests {
    @Test
    func backupRestoreAndResetManifestsRemainExactLocalAndVerified() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = root.appendingPathComponent("workspace-source.json")
        let journal = root.appendingPathComponent("journal-source.jsonl")
        try Data("workspace-private-state".utf8).write(to: workspace)
        try Data("local-core-journal".utf8).write(to: journal)
        let bundle = root.appendingPathComponent("backup.kanamebackup")
        let backupID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
        let service = DesktopRecoveryService()

        let manifest = try service.createBackup(
            at: bundle,
            sources: [
                .init(kind: .workspaceState, fileURL: workspace, archiveName: "workspace.json"),
                .init(kind: .localCoreJournal, fileURL: journal, archiveName: "journal.jsonl"),
            ],
            stateSchemaVersion: 9,
            backupID: backupID,
            createdAtUnixMillis: 10_000
        )

        #expect(manifest.backupID == backupID)
        #expect(manifest.artifacts.map(\.relativePath) == ["artifacts/journal.jsonl", "artifacts/workspace.json"])
        #expect(Set(manifest.excludedScopes) == Set(DesktopRecoveryExcludedScope.allCases))
        #expect(try service.validateBackup(at: bundle) == manifest)
        let bundleMode = try #require(FileManager.default.attributesOfItem(atPath: bundle.path)[.posixPermissions] as? NSNumber)
        let artifactMode = try #require(
            FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent("artifacts/workspace.json").path)[.posixPermissions] as? NSNumber
        )
        #expect(bundleMode.intValue == 0o700)
        #expect(artifactMode.intValue == 0o600)

        let staging = root.appendingPathComponent("restore-staging")
        let restoreID = UUID(uuidString: "00000000-0000-0000-0000-000000000802")!
        let receipt = try service.stageRestore(
            from: bundle,
            at: staging,
            restoreID: restoreID,
            stagedAtUnixMillis: 11_000
        )
        #expect(receipt.restoreID == restoreID)
        #expect(receipt.backupID == backupID)
        #expect(receipt.verifiedArtifactCount == 2)
        #expect(try Data(contentsOf: staging.appendingPathComponent("artifacts/workspace.json")) == Data("workspace-private-state".utf8))
        let restoreManifest = try JSONDecoder().decode(
            DesktopRestoreManifest.self,
            from: Data(contentsOf: staging.appendingPathComponent(DesktopRecoveryService.restoreManifestFileName))
        )
        #expect(restoreManifest.restoreID == restoreID)
        #expect(restoreManifest.backupID == backupID)
        #expect(restoreManifest.artifacts == manifest.artifacts)
        #expect(Set(restoreManifest.preservedScopes) == Set(DesktopRecoveryExcludedScope.allCases))

        let reset = try service.prepareResetManifest(
            verifiedBackupAt: bundle,
            resetID: UUID(uuidString: "00000000-0000-0000-0000-000000000803")!,
            preparedAtUnixMillis: 12_000
        )
        #expect(reset.verifiedBackupID == backupID)
        #expect(reset.localArtifacts == manifest.artifacts)
        #expect(Set(reset.preservedScopes) == Set(DesktopRecoveryExcludedScope.allCases))
        #expect(FileManager.default.fileExists(atPath: workspace.path))
        #expect(FileManager.default.fileExists(atPath: journal.path))
    }

    @Test
    func tamperingFailsClosedBeforeAnyRestoreStagingExists() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("workspace-source.json")
        try Data("original".utf8).write(to: source)
        let bundle = root.appendingPathComponent("backup")
        let service = DesktopRecoveryService()
        try service.createBackup(
            at: bundle,
            sources: [.init(kind: .workspaceState, fileURL: source, archiveName: "workspace.json")],
            stateSchemaVersion: 9,
            createdAtUnixMillis: 1
        )
        try Data("tampered".utf8).write(to: bundle.appendingPathComponent("artifacts/workspace.json"))
        let staging = root.appendingPathComponent("restore")

        #expect(throws: DesktopRecoveryError.integrityMismatch) {
            try service.stageRestore(from: bundle, at: staging, stagedAtUnixMillis: 2)
        }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test
    func backupRejectsSymbolicLinksDuplicatesAndExistingDestinations() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("workspace.json")
        let link = root.appendingPathComponent("workspace-link.json")
        try Data("state".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let service = DesktopRecoveryService()

        #expect(throws: DesktopRecoveryError.unsafeSource) {
            try service.createBackup(
                at: root.appendingPathComponent("linked-backup"),
                sources: [.init(kind: .workspaceState, fileURL: link, archiveName: "workspace.json")],
                stateSchemaVersion: 9,
                createdAtUnixMillis: 1
            )
        }
        #expect(throws: DesktopRecoveryError.duplicateArchiveName) {
            try service.createBackup(
                at: root.appendingPathComponent("duplicate-backup"),
                sources: [
                    .init(kind: .workspaceState, fileURL: source, archiveName: "same.json"),
                    .init(kind: .previousWorkspaceState, fileURL: source, archiveName: "same.json"),
                ],
                stateSchemaVersion: 9,
                createdAtUnixMillis: 1
            )
        }
        #expect(throws: DesktopRecoveryError.unsafeSource) {
            try service.createBackup(
                at: root.appendingPathComponent("traversal-backup"),
                sources: [.init(kind: .workspaceState, fileURL: source, archiveName: "../workspace.json")],
                stateSchemaVersion: 9,
                createdAtUnixMillis: 1
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("linked-backup").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("duplicate-backup").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("traversal-backup").path))
    }

    @Test
    func undeclaredBundleFilesAreRejected() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("workspace.json")
        try Data("state".utf8).write(to: source)
        let bundle = root.appendingPathComponent("backup")
        let service = DesktopRecoveryService()
        try service.createBackup(
            at: bundle,
            sources: [.init(kind: .workspaceState, fileURL: source, archiveName: "workspace.json")],
            stateSchemaVersion: 9,
            createdAtUnixMillis: 1
        )
        try Data("not-declared".utf8).write(to: bundle.appendingPathComponent("unexpected.txt"))

        #expect(throws: DesktopRecoveryError.unexpectedArtifact) {
            try service.validateBackup(at: bundle)
        }
    }

    @Test
    func diagnosticsPersistReceiptsWithoutPrivateStringsOrPaths() throws {
        let sentinel = "PRIVATE-SENTINEL@example.com /Users/person/secret token=abc123"
        let migration = DesktopMigrationReceipt(
            migrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000804")!,
            fromStateSchemaVersion: 8,
            toStateSchemaVersion: 9,
            startedAtUnixMillis: 10,
            completedAtUnixMillis: 12,
            outcome: .failed,
            backupID: nil,
            reasonCode: sentinel
        )
        let event = DesktopRedactedDiagnosticEvent(
            category: "persistence",
            code: "load-failed",
            occurredAtUnixMillis: 12,
            privateDetail: sentinel
        )
        let bundle = DesktopRedactedDiagnosticsBundle(
            generatedAtUnixMillis: 13,
            report: diagnosticReport(),
            migrationReceipts: [migration],
            events: [event]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bundle)
        let json = String(decoding: data, as: UTF8.self)

        #expect(migration.reasonCode?.hasPrefix("redacted-") == true)
        #expect(event.privateDetailByteCount == sentinel.utf8.count)
        #expect(event.privateDetailSHA256?.count == 64)
        #expect(!json.contains("PRIVATE-SENTINEL@example.com"))
        #expect(!json.contains("/Users/"))
        #expect(!json.contains("abc123"))
        #expect(try JSONDecoder().decode(DesktopRedactedDiagnosticsBundle.self, from: data) == bundle)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kaname-recovery-foundation-\(UUID().uuidString)")
    }

    private func diagnosticReport() -> DesktopDiagnosticsReport {
        DesktopDiagnosticsReport(
            schemaVersion: 9,
            generatedAtUnixMillis: 13,
            projectCount: 1,
            activeThreadCount: 2,
            archivedThreadCount: 0,
            unreadThreadCount: 1,
            pendingApprovalCount: 0,
            researchCount: 0,
            emailDraftCount: 0,
            calendarProposalCount: 0,
            automationCount: 0,
            artifactCount: 0,
            auditRecordCount: 1,
            safeMode: true,
            persistenceHealthy: false,
            relayState: "offline",
            queueState: "idle"
        )
    }
}
