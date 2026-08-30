import Darwin
import Foundation

public enum DesktopSupportBundleInspectionError: Error, Equatable, LocalizedError {
    case invalidBundle
    case inspectionDigestMismatch
    case exportedDigestMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidBundle:
            "The inspected diagnostics bundle is malformed. Close it and generate a new inspection."
        case .inspectionDigestMismatch:
            "The diagnostics changed after inspection. Close it and inspect a new bundle before copying or exporting."
        case .exportedDigestMismatch:
            "The exported diagnostics did not match the inspected bundle. Do not share that file."
        }
    }
}

public enum DesktopSupportBundleRedactionCategory: String, CaseIterable, Equatable, Hashable, Sendable {
    case projectRecords
    case conversationRecords
    case pendingApprovalRecords
    case researchRecords
    case emailDraftRecords
    case calendarProposalRecords
    case automationRecords
    case artifactRecords
    case auditRecords
    case runtimeStatusFields
    case migrationReasonFields
    case recoveryEventFields
    case recoveryPrivateDetails
    case resetArtifactPaths
    case resetArtifactDigests

    public var label: String {
        switch self {
        case .projectRecords: "Project records (content and paths omitted)"
        case .conversationRecords: "Conversation records (content omitted)"
        case .pendingApprovalRecords: "Pending approvals (details omitted)"
        case .researchRecords: "Research records (content omitted)"
        case .emailDraftRecords: "Email drafts (content omitted)"
        case .calendarProposalRecords: "Calendar proposals (content omitted)"
        case .automationRecords: "Automation records (details omitted)"
        case .artifactRecords: "Artifacts (names and paths omitted)"
        case .auditRecords: "Audit records (details omitted)"
        case .runtimeStatusFields: "Runtime status fields hashed"
        case .migrationReasonFields: "Migration reason fields hashed"
        case .recoveryEventFields: "Recovery event fields hashed"
        case .recoveryPrivateDetails: "Recovery private details hashed"
        case .resetArtifactPaths: "Reset artifact paths omitted"
        case .resetArtifactDigests: "Reset artifact digests omitted"
        }
    }
}

public struct DesktopSupportBundleRedactionCount: Equatable, Sendable {
    public let category: DesktopSupportBundleRedactionCategory
    public let count: Int

    public init(category: DesktopSupportBundleRedactionCategory, count: Int) {
        self.category = category
        self.count = max(0, count)
    }
}

private enum DesktopSupportBundleOperationalCode {
    private static let reportStates: Set<String> = [
        "idle",
        "offline",
        "unknown",
    ]

    private static let migrationReasons: Set<String> = [
        "initialPersistenceFailed",
        "migration-persistence-failed",
        "migrationFailed",
        "runtimeRollbackUnverified",
        "unknown",
        "unreadableState",
        "unsupportedStateVersion",
    ]

    private static let eventCategories: Set<String> = [
        "persistence",
        "recovery",
        "unknown",
    ]

    private static let eventCodes: Set<String> = [
        "initialPersistenceFailed",
        "migrationFailed",
        "reset-rollback-unverified",
        "reset-runtime-archive-rollback-unverified",
        "restore-rollback-unverified",
        "restore-runtime-activation-rollback-unverified",
        "runtime-activation-rollback-unverified",
        "runtime-archive-rollback-unverified",
        "runtimeRollbackUnverified",
        "unknown",
        "unreadableState",
        "unsupportedStateVersion",
    ]

    static func acceptsReportState(_ value: String) -> Bool {
        accepts(value, allowed: reportStates)
    }

    static func acceptsMigrationReason(_ value: String) -> Bool {
        accepts(value, allowed: migrationReasons)
    }

    static func acceptsEventCategory(_ value: String) -> Bool {
        accepts(value, allowed: eventCategories)
    }

    static func acceptsEventCode(_ value: String) -> Bool {
        accepts(value, allowed: eventCodes)
    }

    static func redactedReportState(_ value: String) -> String {
        redactedIfUnknown(value, allowed: reportStates)
    }

    static func redactedMigrationReason(_ value: String?) -> String? {
        value.map { redactedIfUnknown($0, allowed: migrationReasons) }
    }

    static func redactedEventCategory(_ value: String) -> String {
        redactedIfUnknown(value, allowed: eventCategories)
    }

    static func redactedEventCode(_ value: String) -> String {
        redactedIfUnknown(value, allowed: eventCodes)
    }

    static func isCanonicalRedaction(_ value: String) -> Bool {
        guard value.hasPrefix("redacted-") else { return false }
        let digest = value.dropFirst("redacted-".count)
        return digest.count == 16 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func accepts(_ value: String, allowed: Set<String>) -> Bool {
        allowed.contains(value) || isCanonicalRedaction(value)
    }

    private static func redactedIfUnknown(_ value: String, allowed: Set<String>) -> String {
        // Shape is not provenance. Persisted input is untrusted even when it
        // already resembles one of our redaction tokens, so only an exact
        // operational allowlist value may pass through unchanged.
        guard !allowed.contains(value) else { return value }
        let digest = DesktopRecoveryService.sha256(Data(value.utf8))
        return "redacted-\(digest.prefix(16))"
    }
}

/// An immutable, inspect-before-copy/export snapshot of one diagnostics bundle.
///
/// The summary is derived from the same captured bytes that are shown and
/// exported. `validatedData()` rechecks both the bytes' digest and their
/// redaction summary so a caller cannot silently substitute later app state.
public struct DesktopSupportBundleInspection: Equatable, Sendable {
    private let inspectedBytes: Data
    private let structurallyValid: Bool

    public let sha256: String
    public let redactionCounts: [DesktopSupportBundleRedactionCount]

    public var byteCount: Int { inspectedBytes.count }
    public var isValid: Bool { structurallyValid }

    public init(report: String) {
        let suppliedBytes = Data(report.utf8)
        if let bytes = Self.canonicalRedactedBytes(from: suppliedBytes),
           let counts = Self.redactionCounts(in: bytes) {
            inspectedBytes = bytes
            sha256 = DesktopRecoveryService.sha256(bytes)
            redactionCounts = counts
            structurallyValid = true
        } else {
            inspectedBytes = suppliedBytes
            sha256 = DesktopRecoveryService.sha256(suppliedBytes)
            redactionCounts = []
            structurallyValid = false
        }
    }

    public func validatedData() throws -> Data {
        guard DesktopRecoveryService.sha256(inspectedBytes) == sha256 else {
            throw DesktopSupportBundleInspectionError.inspectionDigestMismatch
        }
        guard structurallyValid,
              Self.redactionCounts(in: inspectedBytes) == redactionCounts else {
            throw DesktopSupportBundleInspectionError.invalidBundle
        }
        return inspectedBytes
    }

    public func validatedString() throws -> String {
        String(decoding: try validatedData(), as: UTF8.self)
    }

    @discardableResult
    public func writeValidated(to url: URL) throws -> String {
        let data = try validatedData()
        try data.write(to: url, options: .atomic)
        let exported = try Data(contentsOf: url, options: .mappedIfSafe)
        guard exported == data,
              DesktopRecoveryService.sha256(exported) == sha256 else {
            throw DesktopSupportBundleInspectionError.exportedDigestMismatch
        }
        return sha256
    }

    /// Rebuild the inspection bytes from a strict canonical bundle while
    /// treating every operational string and stored digest as untrusted input.
    /// This prevents a raw value from self-asserting redaction provenance merely
    /// by using `redacted-<hex>` syntax.
    private static func canonicalRedactedBytes(from data: Data) -> Data? {
        guard let supplied = try? JSONDecoder().decode(DesktopRedactedDiagnosticsBundle.self, from: data) else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let suppliedCanonical = try? encoder.encode(supplied),
              suppliedCanonical == data,
              supplied.schemaVersion == DesktopRedactedDiagnosticsBundle.currentSchemaVersion,
              supplied.report.schemaVersion == DesktopAppSnapshot.currentVersion,
              supplied.generatedAtUnixMillis >= 0,
              supplied.report.generatedAtUnixMillis >= 0,
              supplied.malformedReceiptCount >= 0,
              supplied.rejectedUnsafeReceiptCount >= 0 else { return nil }

        let report = DesktopDiagnosticsReport(
            schemaVersion: supplied.report.schemaVersion,
            generatedAtUnixMillis: supplied.report.generatedAtUnixMillis,
            projectCount: supplied.report.projectCount,
            activeThreadCount: supplied.report.activeThreadCount,
            archivedThreadCount: supplied.report.archivedThreadCount,
            unreadThreadCount: supplied.report.unreadThreadCount,
            pendingApprovalCount: supplied.report.pendingApprovalCount,
            researchCount: supplied.report.researchCount,
            emailDraftCount: supplied.report.emailDraftCount,
            calendarProposalCount: supplied.report.calendarProposalCount,
            automationCount: supplied.report.automationCount,
            artifactCount: supplied.report.artifactCount,
            auditRecordCount: supplied.report.auditRecordCount,
            safeMode: supplied.report.safeMode,
            persistenceHealthy: supplied.report.persistenceHealthy,
            relayState: DesktopSupportBundleOperationalCode.redactedReportState(supplied.report.relayState),
            queueState: DesktopSupportBundleOperationalCode.redactedReportState(supplied.report.queueState)
        )
        let migrationReceipts = supplied.migrationReceipts.compactMap(FileDesktopStateStore.redactedMigrationReceipt)
        guard migrationReceipts.count == supplied.migrationReceipts.count else { return nil }
        let events = supplied.events.compactMap(DesktopRedactedDiagnosticEvent.init(redactingUntrusted:))
        guard events.count == supplied.events.count else { return nil }
        let redacted = DesktopRedactedDiagnosticsBundle(
            generatedAtUnixMillis: supplied.generatedAtUnixMillis,
            report: report,
            migrationReceipts: migrationReceipts,
            restoreReceipts: supplied.restoreReceipts,
            resetReceipts: supplied.resetReceipts,
            events: events,
            malformedReceiptCount: supplied.malformedReceiptCount,
            rejectedUnsafeReceiptCount: supplied.rejectedUnsafeReceiptCount,
            receiptScanTruncated: supplied.receiptScanTruncated
        )
        return try? encoder.encode(redacted)
    }

    private static func redactionCounts(in data: Data) -> [DesktopSupportBundleRedactionCount]? {
        guard let bundle = try? JSONDecoder().decode(DesktopRedactedDiagnosticsBundle.self, from: data) else {
            return nil
        }
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let canonicalData = try? canonicalEncoder.encode(bundle),
              canonicalData == data,
              bundle.schemaVersion == DesktopRedactedDiagnosticsBundle.currentSchemaVersion,
              bundle.generatedAtUnixMillis >= 0,
              bundle.report.schemaVersion == DesktopAppSnapshot.currentVersion,
              bundle.report.generatedAtUnixMillis >= 0 else { return nil }

        let reportCounts = [
            bundle.report.projectCount,
            bundle.report.activeThreadCount,
            bundle.report.archivedThreadCount,
            bundle.report.unreadThreadCount,
            bundle.report.pendingApprovalCount,
            bundle.report.researchCount,
            bundle.report.emailDraftCount,
            bundle.report.calendarProposalCount,
            bundle.report.automationCount,
            bundle.report.artifactCount,
            bundle.report.auditRecordCount,
        ]
        guard reportCounts.allSatisfy({ $0 >= 0 }),
              bundle.malformedReceiptCount >= 0,
              bundle.rejectedUnsafeReceiptCount >= 0,
              DesktopSupportBundleOperationalCode.acceptsReportState(bundle.report.relayState),
              DesktopSupportBundleOperationalCode.acceptsReportState(bundle.report.queueState),
              bundle.migrationReceipts.count <= FileDesktopStateStore.supportBundleMaximumItemsPerKind,
              bundle.restoreReceipts.count <= FileDesktopStateStore.supportBundleMaximumItemsPerKind,
              bundle.resetReceipts.count <= FileDesktopStateStore.supportBundleMaximumItemsPerKind,
              bundle.events.count <= FileDesktopStateStore.supportBundleMaximumItemsPerKind,
              bundle.migrationReceipts.allSatisfy(Self.validMigrationReceipt),
              bundle.restoreReceipts.allSatisfy(Self.validRestoreReceipt),
              bundle.resetReceipts.allSatisfy(Self.validResetReceipt),
              bundle.events.allSatisfy(Self.validEvent),
              bundle.report.unreadThreadCount <= (checkedSum([
                  bundle.report.activeThreadCount,
                  bundle.report.archivedThreadCount,
              ]) ?? -1) else { return nil }

        guard let conversationCount = checkedSum([
            bundle.report.activeThreadCount,
            bundle.report.archivedThreadCount,
        ]),
        let resetArtifactCount = checkedSum(bundle.resetReceipts.map(\.localArtifactCount)) else { return nil }

        let runtimeStatusCount = [bundle.report.relayState, bundle.report.queueState]
            .filter(isRedactedCode).count
        let migrationReasonCount = bundle.migrationReceipts
            .compactMap(\.reasonCode)
            .filter(isRedactedCode).count
        let recoveryEventFieldCount = bundle.events.reduce(into: 0) { count, event in
            count += isRedactedCode(event.category) ? 1 : 0
            count += isRedactedCode(event.code) ? 1 : 0
        }
        let recoveryPrivateDetailCount = bundle.events.filter { $0.privateDetailSHA256 != nil }.count

        return [
            DesktopSupportBundleRedactionCount(category: .projectRecords, count: bundle.report.projectCount),
            DesktopSupportBundleRedactionCount(category: .conversationRecords, count: conversationCount),
            DesktopSupportBundleRedactionCount(category: .pendingApprovalRecords, count: bundle.report.pendingApprovalCount),
            DesktopSupportBundleRedactionCount(category: .researchRecords, count: bundle.report.researchCount),
            DesktopSupportBundleRedactionCount(category: .emailDraftRecords, count: bundle.report.emailDraftCount),
            DesktopSupportBundleRedactionCount(category: .calendarProposalRecords, count: bundle.report.calendarProposalCount),
            DesktopSupportBundleRedactionCount(category: .automationRecords, count: bundle.report.automationCount),
            DesktopSupportBundleRedactionCount(category: .artifactRecords, count: bundle.report.artifactCount),
            DesktopSupportBundleRedactionCount(category: .auditRecords, count: bundle.report.auditRecordCount),
            DesktopSupportBundleRedactionCount(category: .runtimeStatusFields, count: runtimeStatusCount),
            DesktopSupportBundleRedactionCount(category: .migrationReasonFields, count: migrationReasonCount),
            DesktopSupportBundleRedactionCount(category: .recoveryEventFields, count: recoveryEventFieldCount),
            DesktopSupportBundleRedactionCount(category: .recoveryPrivateDetails, count: recoveryPrivateDetailCount),
            DesktopSupportBundleRedactionCount(category: .resetArtifactPaths, count: resetArtifactCount),
            DesktopSupportBundleRedactionCount(category: .resetArtifactDigests, count: resetArtifactCount),
        ]
    }

    private static func validEvent(_ event: DesktopRedactedDiagnosticEvent) -> Bool {
        guard event.occurredAtUnixMillis >= 0,
              event.privateDetailByteCount >= 0,
              DesktopSupportBundleOperationalCode.acceptsEventCategory(event.category),
              DesktopSupportBundleOperationalCode.acceptsEventCode(event.code) else { return false }
        guard let digest = event.privateDetailSHA256 else {
            return event.privateDetailByteCount == 0
        }
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func validMigrationReceipt(_ receipt: DesktopMigrationReceipt) -> Bool {
        receipt.schemaVersion == DesktopMigrationReceipt.currentSchemaVersion
            && receipt.fromStateSchemaVersion >= 1
            && receipt.toStateSchemaVersion >= receipt.fromStateSchemaVersion
            && receipt.startedAtUnixMillis >= 0
            && receipt.completedAtUnixMillis >= receipt.startedAtUnixMillis
            && (receipt.reasonCode.map(DesktopSupportBundleOperationalCode.acceptsMigrationReason) ?? true)
    }

    private static func validRestoreReceipt(_ receipt: DesktopRedactedRestoreReceipt) -> Bool {
        receipt.stagedAtUnixMillis >= 0
            && (0...4_098).contains(receipt.verifiedArtifactCount)
            && receipt.verifiedByteCount >= 0
    }

    private static func validResetReceipt(_ receipt: DesktopRedactedResetReceipt) -> Bool {
        receipt.preparedAtUnixMillis >= 0
            && (0...4_098).contains(receipt.localArtifactCount)
            && receipt.localArtifactByteCount >= 0
            && Set(receipt.preservedScopes) == Set(DesktopRecoveryExcludedScope.allCases)
    }

    private static func isRedactedCode(_ value: String) -> Bool {
        DesktopSupportBundleOperationalCode.isCanonicalRedaction(value)
    }

    private static func checkedSum(_ values: [Int]) -> Int? {
        var result = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }
}

fileprivate extension DesktopRedactedDiagnosticEvent {
    init?(redactingUntrusted event: DesktopRedactedDiagnosticEvent) {
        guard event.occurredAtUnixMillis >= 0,
              event.privateDetailByteCount >= 0 else { return nil }
        let safePrivateDetailSHA256: String?
        if let digest = event.privateDetailSHA256 {
            guard digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            safePrivateDetailSHA256 = DesktopRecoveryService.sha256(Data(digest.utf8))
        } else {
            guard event.privateDetailByteCount == 0 else { return nil }
            safePrivateDetailSHA256 = nil
        }
        let safeEvent = DesktopRedactedDiagnosticEvent(
            category: DesktopSupportBundleOperationalCode.redactedEventCategory(event.category),
            code: DesktopSupportBundleOperationalCode.redactedEventCode(event.code),
            occurredAtUnixMillis: event.occurredAtUnixMillis
        )
        category = safeEvent.category
        code = safeEvent.code
        occurredAtUnixMillis = safeEvent.occurredAtUnixMillis
        privateDetailByteCount = event.privateDetailByteCount
        privateDetailSHA256 = safePrivateDetailSHA256
    }
}

public struct DesktopRecoveryReceiptDiagnostics: Equatable, Sendable {
    public let migrationReceipts: [DesktopMigrationReceipt]
    public let restoreReceipts: [DesktopRedactedRestoreReceipt]
    public let resetReceipts: [DesktopRedactedResetReceipt]
    public let events: [DesktopRedactedDiagnosticEvent]
    public let malformedReceiptCount: Int
    public let rejectedUnsafeReceiptCount: Int
    public let receiptScanTruncated: Bool

    public static let empty = DesktopRecoveryReceiptDiagnostics(
        migrationReceipts: [],
        restoreReceipts: [],
        resetReceipts: [],
        events: [],
        malformedReceiptCount: 0,
        rejectedUnsafeReceiptCount: 0,
        receiptScanTruncated: false
    )
}

extension FileDesktopStateStore {
    static let supportBundleMaximumItemsPerKind = 16
    static let supportBundleMaximumScannedItems = 256
    static let supportBundleMaximumReceiptBytes = 64 * 1_024

    public func loadRedactedRecoveryReceiptDiagnostics() -> DesktopRecoveryReceiptDiagnostics {
        var accumulator = DesktopRecoveryReceiptAccumulator()
        if Self.pathEntryExists(at: recoveryLockMarkerURL) {
            guard accumulator.acceptScannedItem() else {
                accumulator.malformedReceiptCount += 1
                return accumulator.result(maximumItemsPerKind: Self.supportBundleMaximumItemsPerKind)
            }
            if let data = safeReceiptData(at: recoveryLockMarkerURL, accumulator: &accumulator) {
                if let marker = try? JSONDecoder().decode(DesktopRedactedDiagnosticEvent.self, from: data),
                   marker.category == "recovery",
                   marker.privateDetailByteCount == 0,
                   marker.privateDetailSHA256 == nil,
                   let event = DesktopRedactedDiagnosticEvent(redactingUntrusted: marker) {
                    accumulator.events.append(event)
                } else {
                    accumulator.malformedReceiptCount += 1
                }
            }
        }
        scanReceiptDirectory(into: &accumulator)
        scanQuarantineDirectory(into: &accumulator)
        return accumulator.result(maximumItemsPerKind: Self.supportBundleMaximumItemsPerKind)
    }

    private func scanReceiptDirectory(into accumulator: inout DesktopRecoveryReceiptAccumulator) {
        guard safeDirectoryExists(at: receiptDirectoryURL, accumulator: &accumulator) else { return }
        guard let enumerator = FileManager.default.enumerator(
            at: receiptDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            accumulator.malformedReceiptCount += 1
            return
        }
        while let item = enumerator.nextObject() {
            guard accumulator.acceptScannedItem() else { break }
            guard let url = item as? URL else {
                accumulator.malformedReceiptCount += 1
                continue
            }
            let name = url.lastPathComponent
            if name.hasPrefix("migration-"), name.hasSuffix(".json") {
                guard let data = safeReceiptData(at: url, accumulator: &accumulator) else { continue }
                guard let decoded = try? JSONDecoder().decode(DesktopMigrationReceipt.self, from: data),
                      let receipt = Self.redactedMigrationReceipt(decoded) else {
                    accumulator.malformedReceiptCount += 1
                    continue
                }
                accumulator.migrationReceipts.append(receipt)
            } else if name.hasPrefix("restore-"), name.hasSuffix(".json") {
                guard let data = safeReceiptData(at: url, accumulator: &accumulator) else { continue }
                guard let decoded = try? JSONDecoder().decode(DesktopRestoreReceipt.self, from: data),
                      let receipt = DesktopRedactedRestoreReceipt(decoded) else {
                    accumulator.malformedReceiptCount += 1
                    continue
                }
                accumulator.restoreReceipts.append(receipt)
            } else if name.hasPrefix("reset-"), name.hasSuffix(".json") {
                guard let data = safeReceiptData(at: url, accumulator: &accumulator) else { continue }
                guard let decoded = try? JSONDecoder().decode(DesktopResetManifest.self, from: data),
                      let receipt = DesktopRedactedResetReceipt(decoded) else {
                    accumulator.malformedReceiptCount += 1
                    continue
                }
                accumulator.resetReceipts.append(receipt)
            }
        }
    }

    private func scanQuarantineDirectory(into accumulator: inout DesktopRecoveryReceiptAccumulator) {
        guard safeDirectoryExists(at: quarantineDirectoryURL, accumulator: &accumulator) else { return }
        guard let enumerator = FileManager.default.enumerator(
            at: quarantineDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            accumulator.malformedReceiptCount += 1
            return
        }
        while let item = enumerator.nextObject() {
            guard accumulator.acceptScannedItem() else { break }
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                accumulator.malformedReceiptCount += 1
                continue
            }
            if values.isSymbolicLink == true {
                accumulator.rejectedUnsafeReceiptCount += 1
                continue
            }
            guard values.isDirectory == true else { continue }
            let receiptURL = url.appendingPathComponent("receipt.json")
            guard FileManager.default.fileExists(atPath: receiptURL.path) else { continue }
            guard accumulator.acceptScannedItem() else { break }
            guard let data = safeReceiptData(at: receiptURL, accumulator: &accumulator) else { continue }
            guard let decoded = try? JSONDecoder().decode(DesktopRedactedDiagnosticEvent.self, from: data),
                  let event = DesktopRedactedDiagnosticEvent(redactingUntrusted: decoded) else {
                accumulator.malformedReceiptCount += 1
                continue
            }
            accumulator.events.append(event)
        }
    }

    private func safeDirectoryExists(
        at url: URL,
        accumulator: inout DesktopRecoveryReceiptAccumulator
    ) -> Bool {
        guard Self.pathEntryExists(at: url) else { return false }
        guard Self.hasSafeDirectoryChain(
            from: managedRecoveryDirectoryURL,
            through: url
        ) else {
            accumulator.rejectedUnsafeReceiptCount += 1
            return false
        }
        return true
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        guard let metadata = pathMetadata(at: url) else { return false }
        return (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    fileprivate static func pathEntryExists(at url: URL) -> Bool {
        pathMetadata(at: url) != nil
    }

    private static func pathMetadata(at url: URL) -> stat? {
        var metadata = stat()
        let succeeded = url.withUnsafeFileSystemRepresentation { representation in
            guard let representation else { return false }
            return Darwin.lstat(representation, &metadata) == 0
        }
        return succeeded ? metadata : nil
    }

    private static func hasSafeDirectoryChain(from managedRoot: URL, through directory: URL) -> Bool {
        guard let root = canonicalDirectoryWithoutUntrustedSymlinks(managedRoot),
              let target = canonicalDirectoryWithoutUntrustedSymlinks(directory) else { return false }
        let rootPath = root.path
        let targetPath = target.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/"),
              hasOnlyRealDirectoryComponents(target) else { return false }
        return true
    }

    private static func canonicalDirectoryWithoutUntrustedSymlinks(_ url: URL) -> URL? {
        func normalizingSystemAlias(_ path: String) -> String {
            // Foundation can preserve these Darwin spellings even though lstat
            // correctly identifies the top-level entry as a symlink. Normalize
            // only the platform-owned alias itself before comparing the fully
            // resolved spelling and walking every canonical component.
            let systemAliases = [
                ("/var", "/private/var"),
                ("/tmp", "/private/tmp"),
                ("/etc", "/private/etc"),
            ]
            for (alias, destination) in systemAliases
                where path == alias || path.hasPrefix(alias + "/") {
                return destination + String(path.dropFirst(alias.count))
            }
            return path
        }

        let lexicalPath = normalizingSystemAlias(url.standardizedFileURL.path)
        let resolvedPath = normalizingSystemAlias(url.resolvingSymlinksInPath().standardizedFileURL.path)
        guard lexicalPath == resolvedPath else { return nil }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    private static func hasOnlyRealDirectoryComponents(_ url: URL) -> Bool {
        let components = url.pathComponents
        guard components.first == "/" else { return false }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        guard isSafeDirectory(current) else { return false }
        for component in components.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            guard isSafeDirectory(current) else { return false }
        }
        return true
    }

    private static func sameReceiptIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func safeReceiptData(
        at url: URL,
        accumulator: inout DesktopRecoveryReceiptAccumulator
    ) -> Data? {
        guard url.isFileURL,
              Self.hasSafeDirectoryChain(
                  from: managedRecoveryDirectoryURL,
                  through: url.deletingLastPathComponent()
              ),
              let pathBefore = Self.pathMetadata(at: url),
              (pathBefore.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              pathBefore.st_nlink == 1 else {
            accumulator.rejectedUnsafeReceiptCount += 1
            return nil
        }
        guard pathBefore.st_size >= 0,
              pathBefore.st_size <= off_t(Self.supportBundleMaximumReceiptBytes) else {
            accumulator.malformedReceiptCount += 1
            return nil
        }

        let descriptor = url.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            return Darwin.open(representation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            accumulator.rejectedUnsafeReceiptCount += 1
            return nil
        }
        defer { Darwin.close(descriptor) }

        var descriptorBefore = stat()
        guard Darwin.fstat(descriptor, &descriptorBefore) == 0,
              (descriptorBefore.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              descriptorBefore.st_nlink == 1,
              Self.sameReceiptIdentity(pathBefore, descriptorBefore) else {
            accumulator.rejectedUnsafeReceiptCount += 1
            return nil
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        do {
            while true {
                let remaining = Self.supportBundleMaximumReceiptBytes - data.count
                let requestCount = max(1, min(8 * 1_024, remaining + 1))
                guard let chunk = try handle.read(upToCount: requestCount), !chunk.isEmpty else { break }
                data.append(chunk)
                guard data.count <= Self.supportBundleMaximumReceiptBytes else {
                    accumulator.malformedReceiptCount += 1
                    return nil
                }
            }
        } catch {
            accumulator.malformedReceiptCount += 1
            return nil
        }

        var descriptorAfter = stat()
        guard Darwin.fstat(descriptor, &descriptorAfter) == 0,
              let pathAfter = Self.pathMetadata(at: url),
              Self.hasSafeDirectoryChain(
                  from: managedRecoveryDirectoryURL,
                  through: url.deletingLastPathComponent()
              ),
              Self.sameReceiptIdentity(descriptorBefore, descriptorAfter),
              Self.sameReceiptIdentity(descriptorAfter, pathAfter),
              data.count == Int(descriptorAfter.st_size) else {
            accumulator.rejectedUnsafeReceiptCount += 1
            return nil
        }
        return data
    }

    fileprivate static func redactedMigrationReceipt(_ receipt: DesktopMigrationReceipt) -> DesktopMigrationReceipt? {
        guard receipt.schemaVersion == DesktopMigrationReceipt.currentSchemaVersion,
              receipt.fromStateSchemaVersion >= 1,
              receipt.toStateSchemaVersion >= receipt.fromStateSchemaVersion,
              receipt.startedAtUnixMillis >= 0,
              receipt.completedAtUnixMillis >= receipt.startedAtUnixMillis else { return nil }
        return DesktopMigrationReceipt(
            migrationID: receipt.migrationID,
            fromStateSchemaVersion: receipt.fromStateSchemaVersion,
            toStateSchemaVersion: receipt.toStateSchemaVersion,
            startedAtUnixMillis: receipt.startedAtUnixMillis,
            completedAtUnixMillis: receipt.completedAtUnixMillis,
            outcome: receipt.outcome,
            backupID: receipt.backupID,
            reasonCode: DesktopSupportBundleOperationalCode.redactedMigrationReason(receipt.reasonCode)
        )
    }
}

private struct DesktopRecoveryReceiptAccumulator {
    var migrationReceipts: [DesktopMigrationReceipt] = []
    var restoreReceipts: [DesktopRedactedRestoreReceipt] = []
    var resetReceipts: [DesktopRedactedResetReceipt] = []
    var events: [DesktopRedactedDiagnosticEvent] = []
    var malformedReceiptCount = 0
    var rejectedUnsafeReceiptCount = 0
    var receiptScanTruncated = false
    private var scannedItemCount = 0

    mutating func acceptScannedItem() -> Bool {
        guard scannedItemCount < FileDesktopStateStore.supportBundleMaximumScannedItems else {
            receiptScanTruncated = true
            return false
        }
        scannedItemCount += 1
        return true
    }

    func result(maximumItemsPerKind: Int) -> DesktopRecoveryReceiptDiagnostics {
        DesktopRecoveryReceiptDiagnostics(
            migrationReceipts: Array(migrationReceipts.sorted(by: Self.migrationOrder).suffix(maximumItemsPerKind)),
            restoreReceipts: Array(restoreReceipts.sorted(by: Self.restoreOrder).suffix(maximumItemsPerKind)),
            resetReceipts: Array(resetReceipts.sorted(by: Self.resetOrder).suffix(maximumItemsPerKind)),
            events: Array(events.sorted(by: Self.eventOrder).suffix(maximumItemsPerKind)),
            malformedReceiptCount: malformedReceiptCount,
            rejectedUnsafeReceiptCount: rejectedUnsafeReceiptCount,
            receiptScanTruncated: receiptScanTruncated
        )
    }

    private static func migrationOrder(_ lhs: DesktopMigrationReceipt, _ rhs: DesktopMigrationReceipt) -> Bool {
        (lhs.completedAtUnixMillis, lhs.migrationID.uuidString) < (rhs.completedAtUnixMillis, rhs.migrationID.uuidString)
    }

    private static func restoreOrder(_ lhs: DesktopRedactedRestoreReceipt, _ rhs: DesktopRedactedRestoreReceipt) -> Bool {
        (lhs.stagedAtUnixMillis, lhs.restoreID.uuidString) < (rhs.stagedAtUnixMillis, rhs.restoreID.uuidString)
    }

    private static func resetOrder(_ lhs: DesktopRedactedResetReceipt, _ rhs: DesktopRedactedResetReceipt) -> Bool {
        (lhs.preparedAtUnixMillis, lhs.resetID.uuidString) < (rhs.preparedAtUnixMillis, rhs.resetID.uuidString)
    }

    private static func eventOrder(_ lhs: DesktopRedactedDiagnosticEvent, _ rhs: DesktopRedactedDiagnosticEvent) -> Bool {
        (lhs.occurredAtUnixMillis, lhs.category, lhs.code) < (rhs.occurredAtUnixMillis, rhs.category, rhs.code)
    }
}
