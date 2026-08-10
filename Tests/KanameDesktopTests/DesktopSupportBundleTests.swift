import Foundation
import Testing
@testable import KanameDesktop

@MainActor
struct DesktopSupportBundleTests {
    @Test
    func supportBundleIsPrettyRedactedAndStableAcrossRestart() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        let sentinel = "PRIVATE-PROMPT account_8675309 /Users/person/Secret Project"
        var snapshot = DesktopAppSnapshot.starter(now: 1_000)
        snapshot.projects[0].name = sentinel
        snapshot.threads[0].summary = sentinel
        snapshot.threads[0].messages = [DesktopMessage(
            id: "private-message",
            role: .user,
            body: sentinel,
            createdAtUnixMillis: 1_000
        )]
        snapshot.remote.relayStatus = sentinel
        snapshot.remote.queueStatus = sentinel
        try store.save(JSONEncoder().encode(snapshot))

        let migrationID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        try store.persistMigrationReceipt(DesktopMigrationReceipt(
            migrationID: migrationID,
            fromStateSchemaVersion: 12,
            toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
            startedAtUnixMillis: 1_100,
            completedAtUnixMillis: 1_200,
            outcome: .applied,
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000902"),
            reasonCode: sentinel
        ))
        try store.persistRestoreReceipt(DesktopRestoreReceipt(
            restoreID: UUID(uuidString: "00000000-0000-0000-0000-000000000903")!,
            backupID: UUID(uuidString: "00000000-0000-0000-0000-000000000904")!,
            stagedAtUnixMillis: 1_300,
            verifiedArtifactCount: 2,
            verifiedByteCount: 4_096
        ))
        try store.persistResetManifest(DesktopResetManifest(
            resetID: UUID(uuidString: "00000000-0000-0000-0000-000000000905")!,
            preparedAtUnixMillis: 1_400,
            verifiedBackupID: UUID(uuidString: "00000000-0000-0000-0000-000000000906")!,
            localArtifacts: [DesktopRecoveryArtifactManifest(
                kind: .workspaceState,
                relativePath: sentinel,
                byteCount: 8_192,
                sha256: sentinel
            )]
        ))
        let incident = store.quarantineDirectoryURL.appendingPathComponent("incident-test", isDirectory: true)
        try FileManager.default.createDirectory(at: incident, withIntermediateDirectories: true)
        try JSONEncoder().encode(DesktopRedactedDiagnosticEvent(
            category: "recovery",
            code: sentinel,
            occurredAtUnixMillis: 1_500,
            privateDetail: sentinel
        )).write(to: incident.appendingPathComponent("receipt.json"))

        let model = DesktopAppModel(store: store, now: { 2_000 })
        let json = model.redactedSupportBundle()
        let bundle = try decodeBundle(json)

        #expect(json.hasPrefix("{\n"))
        #expect(!json.contains("PRIVATE-PROMPT"))
        #expect(!json.contains("account_8675309"))
        #expect(!json.contains("/Users/person"))
        #expect(bundle.schemaVersion == DesktopRedactedDiagnosticsBundle.currentSchemaVersion)
        #expect(bundle.report.projectCount == snapshot.projects.count)
        #expect(bundle.report.relayState.hasPrefix("redacted-"))
        #expect(bundle.migrationReceipts.map(\.migrationID) == [migrationID])
        #expect(bundle.migrationReceipts[0].reasonCode?.hasPrefix("redacted-") == true)
        #expect(bundle.restoreReceipts.first?.verifiedArtifactCount == 2)
        #expect(bundle.resetReceipts.first?.localArtifactCount == 1)
        #expect(bundle.resetReceipts.first?.localArtifactByteCount == 8_192)
        #expect(bundle.events.first?.code.hasPrefix("redacted-") == true)

        let restarted = DesktopAppModel(store: store, now: { 2_000 })
        #expect(try decodeBundle(restarted.redactedSupportBundle()) == bundle)
        #expect(try JSONDecoder().decode(
            DesktopDiagnosticsReport.self,
            from: Data(restarted.redactedDiagnostics().utf8)
        ).projectCount == snapshot.projects.count)
    }

    @Test
    func malformedOversizedAndSymbolicLinkReceiptsAreExcluded() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        _ = DesktopAppModel(store: store, now: { 3_000 })
        try FileManager.default.createDirectory(at: store.receiptDirectoryURL, withIntermediateDirectories: true)
        try Data("not-json PRIVATE-MALFORMED".utf8).write(
            to: store.receiptDirectoryURL.appendingPathComponent("migration-malformed.json")
        )
        try Data(repeating: 65, count: FileDesktopStateStore.supportBundleMaximumReceiptBytes + 1).write(
            to: store.receiptDirectoryURL.appendingPathComponent("reset-oversized.json")
        )
        let outside = root.appendingPathComponent("PRIVATE-SYMLINK-TARGET.json")
        try JSONEncoder().encode(DesktopRestoreReceipt(
            restoreID: UUID(),
            backupID: UUID(),
            stagedAtUnixMillis: 1,
            verifiedArtifactCount: 1,
            verifiedByteCount: 1
        )).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: store.receiptDirectoryURL.appendingPathComponent("restore-linked.json"),
            withDestinationURL: outside
        )
        let good = DesktopMigrationReceipt(
            migrationID: UUID(),
            fromStateSchemaVersion: 12,
            toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
            startedAtUnixMillis: 1,
            completedAtUnixMillis: 2,
            outcome: .applied,
            backupID: nil
        )
        try store.persistMigrationReceipt(good)

        let bundle = try decodeBundle(DesktopAppModel(store: store, now: { 3_001 }).redactedSupportBundle())

        #expect(bundle.migrationReceipts.map(\.migrationID) == [good.migrationID])
        #expect(bundle.restoreReceipts.isEmpty)
        #expect(bundle.resetReceipts.isEmpty)
        #expect(bundle.malformedReceiptCount == 2)
        #expect(bundle.rejectedUnsafeReceiptCount == 1)
        #expect(!String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self).contains("PRIVATE-"))
    }

    @Test
    func symbolicLinkRecoveryDirectoryIsRejectedWithoutReadingItsReceipts() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        let outsideRecovery = root.appendingPathComponent("PRIVATE-RECOVERY", isDirectory: true)
        let outsideReceipts = outsideRecovery.appendingPathComponent("Receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideReceipts, withIntermediateDirectories: true)
        let receipt = DesktopMigrationReceipt(
            migrationID: UUID(),
            fromStateSchemaVersion: 12,
            toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
            startedAtUnixMillis: 1,
            completedAtUnixMillis: 2,
            outcome: .applied,
            backupID: nil
        )
        try JSONEncoder().encode(receipt).write(
            to: outsideReceipts.appendingPathComponent("migration-private.json")
        )
        try FileManager.default.createSymbolicLink(
            at: desktop.appendingPathComponent("Recovery"),
            withDestinationURL: outsideRecovery
        )

        let loaded = FileDesktopStateStore(
            fileURL: desktop.appendingPathComponent("workspace.json")
        ).loadRedactedRecoveryReceiptDiagnostics()

        #expect(loaded.migrationReceipts.isEmpty)
        #expect(loaded.rejectedUnsafeReceiptCount == 1)
    }

    @Test
    func receiptItemsAndDirectoryScanningAreBounded() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        _ = DesktopAppModel(store: store, now: { 4_000 })
        for index in 0..<20 {
            try store.persistMigrationReceipt(DesktopMigrationReceipt(
                migrationID: UUID(),
                fromStateSchemaVersion: 12,
                toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
                startedAtUnixMillis: Int64(index),
                completedAtUnixMillis: Int64(index),
                outcome: .applied,
                backupID: nil
            ))
        }

        let bounded = store.loadRedactedRecoveryReceiptDiagnostics()
        #expect(bounded.migrationReceipts.count == FileDesktopStateStore.supportBundleMaximumItemsPerKind)
        #expect(bounded.migrationReceipts.first?.completedAtUnixMillis == 4)
        #expect(bounded.migrationReceipts.last?.completedAtUnixMillis == 19)

        for index in 0...FileDesktopStateStore.supportBundleMaximumScannedItems {
            try Data("{".utf8).write(
                to: store.receiptDirectoryURL.appendingPathComponent("restore-malformed-\(index).json")
            )
        }
        let truncated = store.loadRedactedRecoveryReceiptDiagnostics()
        #expect(truncated.receiptScanTruncated)
        #expect(truncated.migrationReceipts.count <= FileDesktopStateStore.supportBundleMaximumItemsPerKind)
        #expect(truncated.restoreReceipts.isEmpty)
    }

    @Test
    func schemaOneDiagnosticsBundlesStillDecodeWithEmptyNewReceiptFields() throws {
        let original = DesktopRedactedDiagnosticsBundle(
            generatedAtUnixMillis: 5_000,
            report: DesktopDiagnosticsReport(
                schemaVersion: DesktopAppSnapshot.currentVersion,
                generatedAtUnixMillis: 5_000,
                projectCount: 1,
                activeThreadCount: 1,
                archivedThreadCount: 0,
                unreadThreadCount: 0,
                pendingApprovalCount: 0,
                researchCount: 0,
                emailDraftCount: 0,
                calendarProposalCount: 0,
                automationCount: 0,
                artifactCount: 0,
                auditRecordCount: 0,
                safeMode: true,
                persistenceHealthy: true,
                relayState: "offline",
                queueState: "idle"
            ),
            migrationReceipts: [],
            events: []
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)
        ) as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "restoreReceipts")
        object.removeValue(forKey: "resetReceipts")
        object.removeValue(forKey: "malformedReceiptCount")
        object.removeValue(forKey: "rejectedUnsafeReceiptCount")
        object.removeValue(forKey: "receiptScanTruncated")

        let decoded = try JSONDecoder().decode(
            DesktopRedactedDiagnosticsBundle.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.restoreReceipts.isEmpty)
        #expect(decoded.resetReceipts.isEmpty)
        #expect(decoded.malformedReceiptCount == 0)
        #expect(decoded.rejectedUnsafeReceiptCount == 0)
        #expect(!decoded.receiptScanTruncated)
    }

    private func decodeBundle(_ json: String) throws -> DesktopRedactedDiagnosticsBundle {
        try JSONDecoder().decode(DesktopRedactedDiagnosticsBundle.self, from: Data(json.utf8))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kaname-support-bundle-\(UUID().uuidString)")
    }
}
