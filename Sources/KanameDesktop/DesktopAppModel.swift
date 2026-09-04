import Combine
import CryptoKit
import Foundation
import KanameConnectivity
import KanameDomain
import KanameLocalCore
#if os(macOS)
import Darwin
#endif

@MainActor
public final class DesktopAppModel: ObservableObject {
    @Published public private(set) var snapshot: DesktopAppSnapshot
    @Published public private(set) var persistenceError: String?
    @Published public private(set) var recoveryStatus: DesktopRecoveryStatus?

    private let store: any DesktopStateStoring
    let now: () -> Int64
    let encoder: JSONEncoder
    private let decoder: JSONDecoder
    var providerEventIDs: Set<String>
    // SwiftUI owns the visible draft. This non-published cache keeps keystrokes
    // off the monolithic workspace encoder until an idle or explicit checkpoint.
    private var composerDraftCache: [String: String] = [:]
    private var composerDraftSaveTask: _Concurrency.Task<Void, Never>?
    private var composerDraftGeneration: UInt64 = 0
    private var persistedComposerDraftGeneration: UInt64 = 0
    private let composerDraftSaveDelay: Duration

    public init(
        store: any DesktopStateStoring = FileDesktopStateStore.applicationSupport(),
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        composerDraftSaveDelay: Duration = .milliseconds(300)
    ) {
        self.store = store
        self.now = now
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.providerEventIDs = []
        self.composerDraftSaveDelay = composerDraftSaveDelay
        self.recoveryStatus = nil
        let timestamp = now()
        let runtimeRecoveryLockDetected: Bool
        if let fileStore = store as? FileDesktopStateStore {
            do {
                runtimeRecoveryLockDetected = try fileStore.loadRecoveryLockMarker() != nil
            } catch {
                runtimeRecoveryLockDetected = true
            }
        } else {
            runtimeRecoveryLockDetected = false
        }
        if runtimeRecoveryLockDetected {
            do {
                if let data = try store.load(),
                   let restored = try? Self.currentSnapshot(from: data, decoder: decoder, now: timestamp) {
                    self.snapshot = restored.snapshot
                } else {
                    self.snapshot = DesktopAppSnapshot.starter(now: timestamp)
                }
            } catch {
                self.snapshot = DesktopAppSnapshot.starter(now: timestamp)
            }
            let previousWorkspaceAvailable: Bool
            if let recoveryStore = store as? any DesktopRecoveryStateStoring {
                previousWorkspaceAvailable = ((try? recoveryStore.loadRecovery()) ?? nil) != nil
            } else {
                previousWorkspaceAvailable = false
            }
            self.recoveryStatus = DesktopRecoveryStatus(
                reason: .runtimeRollbackUnverified,
                detectedStateSchemaVersion: snapshot.version,
                quarantineCreated: false,
                previousWorkspaceAvailable: previousWorkspaceAvailable
            )
            self.persistenceError = DesktopModelRecoveryError.recoveryRollbackFailed.localizedDescription
        } else {
            do {
            if let data = try store.load() {
                let declaredVersion = Self.declaredSchemaVersion(from: data)
                var backupID: UUID?
                let migrationID = UUID()
                if let declaredVersion, declaredVersion < DesktopAppSnapshot.currentVersion,
                   let fileStore = store as? FileDesktopStateStore {
                    backupID = try fileStore.createPrivateBackupHistory(
                        stateSchemaVersion: declaredVersion,
                        createdAtUnixMillis: timestamp
                    )?.backupID
                }
                let restored = try Self.currentSnapshot(from: data, decoder: decoder, now: timestamp)
                if restored.didMigrate {
                    do {
                        let migratedData = try encoder.encode(restored.snapshot)
                        try store.save(migratedData)
                        guard try store.load() == migratedData else {
                            throw DesktopModelRecoveryError.persistenceVerificationFailed
                        }
                        try (store as? FileDesktopStateStore)?.persistMigrationReceipt(DesktopMigrationReceipt(
                            migrationID: migrationID,
                            fromStateSchemaVersion: declaredVersion ?? restored.snapshot.version,
                            toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
                            startedAtUnixMillis: timestamp,
                            completedAtUnixMillis: now(),
                            outcome: .applied,
                            backupID: backupID
                        ))
                    } catch {
                        try? (store as? FileDesktopStateStore)?.persistMigrationReceipt(DesktopMigrationReceipt(
                            migrationID: migrationID,
                            fromStateSchemaVersion: declaredVersion ?? 0,
                            toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
                            startedAtUnixMillis: timestamp,
                            completedAtUnixMillis: now(),
                            outcome: .failed,
                            backupID: backupID,
                            reasonCode: "migration-persistence-failed"
                        ))
                        throw error
                    }
                }
                self.snapshot = restored.snapshot
            } else {
                let starter = DesktopAppSnapshot.starter(now: timestamp)
                self.snapshot = starter
                try store.save(try encoder.encode(starter))
            }
            } catch {
            let primaryData: Data?
            let primaryReadFailed: Bool
            do {
                primaryData = try store.load()
                primaryReadFailed = false
            } catch {
                primaryData = nil
                primaryReadFailed = true
            }
            let declaredVersion = primaryData.flatMap(Self.declaredSchemaVersion(from:))
            let reason: DesktopRecoveryReason
            if let declaredVersion, declaredVersion > DesktopAppSnapshot.currentVersion {
                reason = .unsupportedStateVersion
            } else if declaredVersion != nil {
                reason = .migrationFailed
            } else if primaryReadFailed {
                reason = .unreadableState
            } else if primaryData == nil {
                reason = .initialPersistenceFailed
            } else {
                reason = .unreadableState
            }
            let quarantineCreated = ((try? (store as? FileDesktopStateStore)?.quarantinePrimary(
                reasonCode: reason.rawValue,
                detectedAtUnixMillis: timestamp
            )) ?? nil) != nil
            var previousWorkspaceAvailable = false
            if let recoveryStore = store as? any DesktopRecoveryStateStoring,
               let recoveryData = try? recoveryStore.loadRecovery(),
               let recovered = try? Self.currentSnapshot(from: recoveryData, decoder: decoder, now: timestamp) {
                self.snapshot = recovered.snapshot
                previousWorkspaceAvailable = true
            } else {
                self.snapshot = DesktopAppSnapshot.starter(now: timestamp)
            }
            self.recoveryStatus = DesktopRecoveryStatus(
                reason: reason,
                detectedStateSchemaVersion: declaredVersion,
                quarantineCreated: quarantineCreated,
                previousWorkspaceAvailable: previousWorkspaceAvailable
            )
            // Recovery is a first-class blocking workspace, not a transient
            // save error. Keeping the generic alert clear lets Recovery Center
            // present the preserved-state choices without an alert obscuring it.
                self.persistenceError = nil
            }
        }
        providerEventIDs = Set(snapshot.operations.providerEvents.map(\.id))
        composerDraftCache = snapshot.operations.composerDrafts
        persistedComposerDraftGeneration = composerDraftGeneration
    }

    public var isRecoveryReadOnly: Bool { recoveryStatus != nil }

    public var requiresArchiveConfirmation: Bool {
        snapshot.preferences.confirmBeforeArchiving
    }

    public func composerDraft(threadID: String) -> String {
        composerDraftCache[threadID] ?? ""
    }

    public func composerAttachments(threadID: String) -> [ConversationImageAttachment] {
        snapshot.operations.composerAttachmentDrafts[threadID] ?? []
    }

    @discardableResult
    public func updateComposerDraft(threadID: String, body: String) -> Bool {
        guard snapshot.threads.contains(where: { $0.id == threadID }), body.utf8.count <= 32_000 else { return false }
        guard recoveryStatus == nil else {
            persistenceError = "Kaname is keeping this recovery workspace read-only until verified state is restored or exported."
            return false
        }
        guard composerDraftCache[threadID] != body else { return persistenceError == nil }
        if body.isEmpty {
            composerDraftCache.removeValue(forKey: threadID)
        } else {
            composerDraftCache[threadID] = body
        }
        composerDraftGeneration &+= 1
        scheduleComposerDraftPersistence()
        return persistenceError == nil
    }

    @discardableResult
    public func flushComposerDrafts() -> Bool {
        guard composerDraftGeneration != persistedComposerDraftGeneration else {
            return true
        }
        composerDraftSaveTask?.cancel()
        composerDraftSaveTask = nil
        return mutate { _ in }
    }

    @discardableResult
    public func addComposerAttachment(
        threadID: String,
        attachment: ConversationImageAttachment
    ) -> Bool {
        guard snapshot.threads.contains(where: { $0.id == threadID }) else { return false }
        let current = composerAttachments(threadID: threadID)
        guard current.count < ConversationImageAttachment.maximumCountPerMessage,
              !current.contains(where: { $0.id == attachment.id }) else { return false }
        mutate { $0.operations.composerAttachmentDrafts[threadID, default: []].append(attachment) }
        return persistenceError == nil
    }

    @discardableResult
    public func removeComposerAttachment(
        threadID: String,
        attachmentID: String
    ) -> ConversationImageAttachment? {
        var removed: ConversationImageAttachment?
        mutate { snapshot in
            guard var attachments = snapshot.operations.composerAttachmentDrafts[threadID],
                  let index = attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
            removed = attachments.remove(at: index)
            if attachments.isEmpty {
                snapshot.operations.composerAttachmentDrafts.removeValue(forKey: threadID)
            } else {
                snapshot.operations.composerAttachmentDrafts[threadID] = attachments
            }
        }
        return removed
    }

    public func clearComposerDraft(threadID: String) {
        if composerDraftCache.removeValue(forKey: threadID) != nil {
            composerDraftGeneration &+= 1
        }
        composerDraftSaveTask?.cancel()
        composerDraftSaveTask = nil
        mutate { snapshot in
            snapshot.operations.composerDrafts.removeValue(forKey: threadID)
            snapshot.operations.composerAttachmentDrafts.removeValue(forKey: threadID)
        }
    }

    public func clearPersistenceError() {
        guard recoveryStatus == nil else { return }
        persistenceError = nil
    }

    @discardableResult
    public func exportRecoveryBackup(to destination: URL) throws -> DesktopBackupManifest {
        guard flushComposerDrafts() else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
        guard let fileStore = store as? FileDesktopStateStore else {
            throw DesktopModelRecoveryError.recoveryUnavailable
        }
        return try fileStore.exportRecoveryBackup(
            to: destination,
            stateSchemaVersion: recoveryStatus?.detectedStateSchemaVersion ?? snapshot.version,
            createdAtUnixMillis: now()
        )
    }

    public func workflowInstallationStorageURL(workflowID: String) -> URL? {
        guard workflowID.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil,
              let fileStore = store as? FileDesktopStateStore else { return nil }
        return fileStore.applicationSupportRootURL
            .appendingPathComponent("WorkflowInstallations", isDirectory: true)
            .appendingPathComponent(workflowID, isDirectory: true)
    }

    public func workflowCapabilityStore() -> DesktopWorkflowCapabilityStore? {
        guard let fileStore = store as? FileDesktopStateStore else { return nil }
        return DesktopWorkflowCapabilityStore(rootDirectory: fileStore.workflowCapabilitiesDirectoryURL)
    }

    public func restorePreviousWorkspace() throws {
        guard recoveryStatus != nil else { throw DesktopModelRecoveryError.recoveryNotRequired }
        guard recoveryStatus?.reason != .runtimeRollbackUnverified else {
            throw DesktopModelRecoveryError.restoreArtifactInvalid
        }
        var runtimeLock: KanameRuntimeRecoveryFileLock?
        if let fileStore = store as? FileDesktopStateStore {
            runtimeLock = try fileStore.acquireExclusiveRuntimeRecoveryLock()
            try fileStore.requireRuntimeQuiescent()
            guard try !fileStore.hasRuntimeState() else {
                throw DesktopModelRecoveryError.restoreArtifactInvalid
            }
        }
        defer { _ = runtimeLock }
        guard let recoveryStore = store as? any DesktopRecoveryStateStoring,
              let recoveryData = try recoveryStore.loadRecovery() else {
            throw DesktopModelRecoveryError.previousWorkspaceUnavailable
        }
        var receipt: DesktopRestoreReceipt?
        if let fileStore = store as? FileDesktopStateStore,
           let backup = try fileStore.createPrivateBackupHistory(
               stateSchemaVersion: recoveryStatus?.detectedStateSchemaVersion ?? snapshot.version,
               createdAtUnixMillis: now()
           ) {
            let matches = backup.artifacts.filter { $0.kind == .previousWorkspaceState }
            guard matches.count == 1, let artifact = matches.first,
                  artifact.byteCount == Int64(recoveryData.count),
                  artifact.sha256 == DesktopRecoveryService.sha256(recoveryData) else {
                throw DesktopModelRecoveryError.restoreArtifactInvalid
            }
            receipt = DesktopRestoreReceipt(
                restoreID: UUID(),
                backupID: backup.backupID,
                stagedAtUnixMillis: now(),
                verifiedArtifactCount: 1,
                verifiedByteCount: Int64(recoveryData.count)
            )
        }
        try restoreVerifiedWorkspaceData(recoveryData, receipt: receipt)
    }

    public func restoreWorkspace(
        fromVerifiedBackup bundleURL: URL,
        artifactKind: DesktopRecoveryArtifactKind = .workspaceState
    ) throws {
        guard recoveryStatus != nil else { throw DesktopModelRecoveryError.recoveryNotRequired }
        guard artifactKind == .workspaceState || artifactKind == .previousWorkspaceState else {
            throw DesktopModelRecoveryError.restoreArtifactInvalid
        }
        let service = DesktopRecoveryService()
        let manifest = try service.validateBackup(at: bundleURL)
        if recoveryStatus?.reason == .runtimeRollbackUnverified,
           manifest.runtimeStateIncluded != true {
            throw DesktopModelRecoveryError.restoreArtifactInvalid
        }
        let data = try service.verifiedArtifactData(kind: artifactKind, from: bundleURL)
        let artifact = try Self.requireSingleRecoveryArtifact(kind: artifactKind, in: manifest)
        let restoreID = UUID()
        var runtimeTransaction: DesktopRuntimeRestoreTransaction?
        var originalWorkspaceData: Data?
        var runtimeLock: KanameRuntimeRecoveryFileLock?
        if let fileStore = store as? FileDesktopStateStore {
            runtimeLock = try fileStore.acquireExclusiveRuntimeRecoveryLock()
            try fileStore.requireRuntimeQuiescent()
            originalWorkspaceData = try fileStore.load()
            _ = try fileStore.createPrivateBackupHistory(
                stateSchemaVersion: recoveryStatus?.detectedStateSchemaVersion ?? snapshot.version,
                createdAtUnixMillis: now(),
                includesRuntimeState: true
            )
            do {
                runtimeTransaction = try fileStore.activateVerifiedRuntimeRestore(
                    from: bundleURL,
                    restoreID: restoreID
                )
            } catch {
                if let recoveryError = error as? DesktopModelRecoveryError,
                   recoveryError == .recoveryRollbackFailed {
                    try forceRecoveryReadOnlyAfterRollbackFailure(
                        fileStore: fileStore,
                        code: "restore-runtime-activation-rollback-unverified"
                    )
                }
                throw error
            }
        }
        defer { _ = runtimeLock }
        let receipt = DesktopRestoreReceipt(
            restoreID: restoreID,
            backupID: manifest.backupID,
            stagedAtUnixMillis: now(),
            verifiedArtifactCount: manifest.runtimeStateIncluded == true ? manifest.artifacts.count : 1,
            verifiedByteCount: manifest.runtimeStateIncluded == true
                ? manifest.artifacts.reduce(0) { $0 + $1.byteCount }
                : artifact.byteCount
        )
        do {
            try restoreVerifiedWorkspaceData(
                data,
                receipt: receipt,
                clearsRecoveryLockMarker: manifest.runtimeStateIncluded == true
            )
        } catch {
            var workspaceRollbackVerified = false
            var runtimeRollbackVerified = runtimeTransaction == nil
            if let fileStore = store as? FileDesktopStateStore {
                if let originalWorkspaceData {
                    do {
                        try fileStore.saveRecovered(originalWorkspaceData)
                        workspaceRollbackVerified = try fileStore.load() == originalWorkspaceData
                    } catch {
                        workspaceRollbackVerified = false
                    }
                }
                if let runtimeTransaction {
                    do {
                        try fileStore.rollbackRuntimeRestore(runtimeTransaction)
                        runtimeRollbackVerified = true
                    } catch {
                        runtimeRollbackVerified = false
                    }
                }
                if !workspaceRollbackVerified || !runtimeRollbackVerified {
                    try forceRecoveryReadOnlyAfterRollbackFailure(
                        fileStore: fileStore,
                        code: "restore-rollback-unverified"
                    )
                    throw DesktopModelRecoveryError.recoveryRollbackFailed
                }
            }
            throw error
        }
    }

    @discardableResult
    public func prepareReset(verifiedBackupAt bundleURL: URL) throws -> DesktopResetManifest {
        let manifest = try DesktopRecoveryService().prepareResetManifest(
            verifiedBackupAt: bundleURL,
            preparedAtUnixMillis: now()
        )
        try (store as? FileDesktopStateStore)?.persistResetManifest(manifest)
        return manifest
    }

    @discardableResult
    public func resetWorkspace(verifiedBackupAt bundleURL: URL) throws -> DesktopResetManifest {
        _ = try DesktopRecoveryService().validateBackup(at: bundleURL)
        guard let fileStore = store as? FileDesktopStateStore,
              let recoveryStore = store as? any DesktopRecoveryStateStoring else {
            throw DesktopModelRecoveryError.recoveryUnavailable
        }
        let runtimeLock = try fileStore.acquireExclusiveRuntimeRecoveryLock()
        defer { _ = runtimeLock }
        try fileStore.requireRuntimeQuiescent()
        guard let currentBackup = try fileStore.createPrivateBackupHistory(
            stateSchemaVersion: recoveryStatus?.detectedStateSchemaVersion ?? snapshot.version,
            createdAtUnixMillis: now(),
            includesRuntimeState: true
        ) else {
            throw DesktopModelRecoveryError.recoveryUnavailable
        }
        let manifest = DesktopResetManifest(
            resetID: UUID(),
            preparedAtUnixMillis: now(),
            verifiedBackupID: currentBackup.backupID,
            localArtifacts: currentBackup.artifacts
        )
        try fileStore.persistResetManifest(manifest)
        let originalWorkspaceData = try fileStore.load()
        let runtimeMoves: [DesktopRuntimeArchiveMove]
        do {
            runtimeMoves = try fileStore.archiveRuntimeState(resetID: manifest.resetID)
        } catch {
            if let recoveryError = error as? DesktopModelRecoveryError,
               recoveryError == .recoveryRollbackFailed {
                try forceRecoveryReadOnlyAfterRollbackFailure(
                    fileStore: fileStore,
                    code: "reset-runtime-archive-rollback-unverified"
                )
            }
            throw error
        }
        let starter = DesktopAppSnapshot.starter(now: now())
        let encoded = try encoder.encode(starter)
        do {
            try recoveryStore.saveRecovered(encoded)
            guard try recoveryStore.load() == encoded else {
                throw DesktopModelRecoveryError.persistenceVerificationFailed
            }
            try fileStore.clearRecoveryLockMarker()
        } catch {
            var workspaceRollbackVerified = false
            var runtimeRollbackVerified = false
            if let originalWorkspaceData {
                do {
                    try fileStore.saveRecovered(originalWorkspaceData)
                    workspaceRollbackVerified = try fileStore.load() == originalWorkspaceData
                } catch {
                    workspaceRollbackVerified = false
                }
            }
            do {
                try fileStore.restoreArchivedRuntimeState(runtimeMoves)
                runtimeRollbackVerified = true
            } catch {
                runtimeRollbackVerified = false
            }
            if !workspaceRollbackVerified || !runtimeRollbackVerified {
                try forceRecoveryReadOnlyAfterRollbackFailure(
                    fileStore: fileStore,
                    code: "reset-rollback-unverified"
                )
                throw DesktopModelRecoveryError.recoveryRollbackFailed
            }
            throw error
        }
        snapshot = starter
        resetComposerDraftCacheFromSnapshot()
        providerEventIDs = []
        recoveryStatus = nil
        persistenceError = nil
        return manifest
    }

    private func forceRecoveryReadOnlyAfterRollbackFailure(
        fileStore: FileDesktopStateStore,
        code: String
    ) throws {
        recoveryStatus = DesktopRecoveryStatus(
            reason: .runtimeRollbackUnverified,
            detectedStateSchemaVersion: snapshot.version,
            quarantineCreated: false,
            previousWorkspaceAvailable: false
        )
        persistenceError = DesktopModelRecoveryError.recoveryRollbackFailed.localizedDescription
        let event = DesktopRedactedDiagnosticEvent(
            category: "recovery",
            code: code,
            occurredAtUnixMillis: now()
        )
        do {
            try fileStore.persistRecoveryLockMarker(event)
        } catch {
            throw DesktopModelRecoveryError.recoveryRollbackFailed
        }
        try? fileStore.persistRecoveryFailureEvent(event)
    }

    public func redactedDiagnostics() -> String {
        let diagnosticsEncoder = JSONEncoder()
        diagnosticsEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? diagnosticsEncoder.encode(makeRedactedDiagnosticsReport()) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public func redactedSupportBundle() -> String {
        let receipts = (store as? FileDesktopStateStore)?.loadRedactedRecoveryReceiptDiagnostics() ?? .empty
        let bundle = DesktopRedactedDiagnosticsBundle(
            generatedAtUnixMillis: now(),
            report: makeRedactedDiagnosticsReport(),
            migrationReceipts: receipts.migrationReceipts,
            restoreReceipts: receipts.restoreReceipts,
            resetReceipts: receipts.resetReceipts,
            events: receipts.events,
            malformedReceiptCount: receipts.malformedReceiptCount,
            rejectedUnsafeReceiptCount: receipts.rejectedUnsafeReceiptCount,
            receiptScanTruncated: receipts.receiptScanTruncated
        )
        let diagnosticsEncoder = JSONEncoder()
        diagnosticsEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? diagnosticsEncoder.encode(bundle) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func makeRedactedDiagnosticsReport() -> DesktopDiagnosticsReport {
        DesktopDiagnosticsReport(
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
    }

    @discardableResult
    func mutate(_ change: (inout DesktopAppSnapshot) -> Void) -> Bool {
        guard recoveryStatus == nil else {
            persistenceError = "Kaname is keeping this recovery workspace read-only until verified state is restored or exported."
            return false
        }
        var changed = snapshot
        change(&changed)
        changed.operations.composerDrafts = composerDraftCache
        changed.lastSavedAtUnixMillis = now()
        do {
            try store.save(try encoder.encode(changed))
            snapshot = changed
            persistedComposerDraftGeneration = composerDraftGeneration
            composerDraftSaveTask?.cancel()
            composerDraftSaveTask = nil
            persistenceError = nil
            return true
        } catch {
            persistenceError = "Kaname could not save this local change. The previous durable workspace remains intact."
            return false
        }
    }

    @discardableResult
    func mutateThread(id: String, change: (inout DesktopThread) -> Void) -> Bool {
        var didFindThread = false
        let persisted = mutate { workspace in
            let matches = workspace.threads.indices.filter { workspace.threads[$0].id == id }
            guard let index = matches.first else { return }
            change(&workspace.threads[index])
            didFindThread = true
        }
        return didFindThread && persisted
    }

    @discardableResult
    func mutateRecord<Record: Identifiable>(
        at keyPath: WritableKeyPath<DesktopAppSnapshot, [Record]>,
        id: String,
        change: (inout Record) -> Void,
        audit: DesktopAuditRecord? = nil
    ) -> Bool where Record.ID == String {
        var didFindRecord = false
        let persisted = mutate { snapshot in
            didFindRecord = snapshot.changeRecord(at: keyPath, id: id, change: change)
            if didFindRecord, let audit { snapshot.operations.audit.append(audit) }
        }
        return didFindRecord && persisted
    }

    static func stableLocalDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func provisionalConversationTitle(from firstMessage: String) -> String {
        let collapsed = firstMessage.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let maximumCharacters = 72
        guard collapsed.count > maximumCharacters else { return collapsed }
        return "\(String(collapsed.prefix(maximumCharacters)).trimmingCharacters(in: .whitespacesAndNewlines))…"
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

    public static func declaredSchemaVersion(from data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? Int
    }

    private static func requireSingleRecoveryArtifact(
        kind: DesktopRecoveryArtifactKind,
        in manifest: DesktopBackupManifest
    ) throws -> DesktopRecoveryArtifactManifest {
        let matches = manifest.artifacts.filter { $0.kind == kind }
        guard matches.count == 1, let artifact = matches.first else {
            throw DesktopModelRecoveryError.restoreArtifactInvalid
        }
        return artifact
    }

    private func restoreVerifiedWorkspaceData(
        _ data: Data,
        receipt: DesktopRestoreReceipt?,
        clearsRecoveryLockMarker: Bool = false
    ) throws {
        let restored: (snapshot: DesktopAppSnapshot, didMigrate: Bool)
        do {
            restored = try Self.currentSnapshot(from: data, decoder: decoder, now: now())
        } catch {
            throw DesktopModelRecoveryError.restoreArtifactInvalid
        }
        let encoded = try encoder.encode(restored.snapshot)
        guard let recoveryStore = store as? any DesktopRecoveryStateStoring else {
            throw DesktopModelRecoveryError.recoveryUnavailable
        }
        try recoveryStore.saveRecovered(encoded)
        guard try recoveryStore.load() == encoded else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
        if restored.didMigrate, let fileStore = store as? FileDesktopStateStore {
            try fileStore.persistMigrationReceipt(DesktopMigrationReceipt(
                migrationID: UUID(),
                fromStateSchemaVersion: Self.declaredSchemaVersion(from: data) ?? 0,
                toStateSchemaVersion: DesktopAppSnapshot.currentVersion,
                startedAtUnixMillis: now(),
                completedAtUnixMillis: now(),
                outcome: .applied,
                backupID: receipt?.backupID
            ))
        }
        if let receipt {
            try (store as? FileDesktopStateStore)?.persistRestoreReceipt(receipt)
        }
        if clearsRecoveryLockMarker {
            try (store as? FileDesktopStateStore)?.clearRecoveryLockMarker()
        }
        snapshot = restored.snapshot
        resetComposerDraftCacheFromSnapshot()
        providerEventIDs = Set(restored.snapshot.operations.providerEvents.map(\.id))
        recoveryStatus = nil
        persistenceError = nil
    }

    private func scheduleComposerDraftPersistence() {
        let generation = composerDraftGeneration
        composerDraftSaveTask?.cancel()
        composerDraftSaveTask = _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await _Concurrency.Task<Never, Never>.sleep(for: composerDraftSaveDelay)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard generation == composerDraftGeneration else { return }
            composerDraftSaveTask = nil
            _ = mutate { _ in }
        }
    }

    private func resetComposerDraftCacheFromSnapshot() {
        composerDraftSaveTask?.cancel()
        composerDraftSaveTask = nil
        composerDraftCache = snapshot.operations.composerDrafts
        composerDraftGeneration &+= 1
        persistedComposerDraftGeneration = composerDraftGeneration
    }
}
