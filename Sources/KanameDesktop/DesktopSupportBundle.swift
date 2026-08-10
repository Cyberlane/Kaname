import Foundation

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
        if FileManager.default.fileExists(atPath: recoveryLockMarkerURL.path) {
            do {
                guard accumulator.acceptScannedItem() else {
                    accumulator.malformedReceiptCount += 1
                    return accumulator.result(maximumItemsPerKind: Self.supportBundleMaximumItemsPerKind)
                }
                if let marker = try loadRecoveryLockMarker() {
                    accumulator.events.append(marker)
                } else {
                    accumulator.malformedReceiptCount += 1
                }
            } catch {
                accumulator.malformedReceiptCount += 1
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
            guard let decoded = try? JSONDecoder().decode(DesktopRedactedDiagnosticEvent.self, from: data) else {
                accumulator.malformedReceiptCount += 1
                continue
            }
            accumulator.events.append(DesktopRedactedDiagnosticEvent(
                category: decoded.category,
                code: decoded.code,
                occurredAtUnixMillis: max(0, decoded.occurredAtUnixMillis)
            ))
        }
    }

    private func safeDirectoryExists(
        at url: URL,
        accumulator: inout DesktopRecoveryReceiptAccumulator
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let managedRoot = managedRecoveryDirectoryURL
        guard Self.isSafeDirectory(managedRoot),
              (url == managedRoot || Self.isSafeDirectory(url)) else {
            accumulator.rejectedUnsafeReceiptCount += 1
            return false
        }
        return true
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func safeReceiptData(
        at url: URL,
        accumulator: inout DesktopRecoveryReceiptAccumulator
    ) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            accumulator.rejectedUnsafeReceiptCount += 1
            return nil
        }
        guard let byteCount = values.fileSize,
              (0...Self.supportBundleMaximumReceiptBytes).contains(byteCount),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= Self.supportBundleMaximumReceiptBytes else {
            accumulator.malformedReceiptCount += 1
            return nil
        }
        return data
    }

    private static func redactedMigrationReceipt(_ receipt: DesktopMigrationReceipt) -> DesktopMigrationReceipt? {
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
            reasonCode: receipt.reasonCode
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
