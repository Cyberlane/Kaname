import Foundation
import KanameConnectivity
import KanameDesktop
import KanameLocalCore

public enum DesktopAutomationServiceRunResult: Equatable, Sendable {
    case healthy(advancedRuleCount: Int)
    case unavailable
    case disabled
}

/// The long lived, app independent half of workflow automation.
///
/// This service only reads the durable Rust projection and applies already
/// approved standing rules. Provider polling and connector dispatch are owned
/// by the sibling worker process, while the desktop UI remains an observer.
/// No DesktopAppModel is opened, so a running UI cannot race its workspace
/// snapshot or claim state.
public struct DesktopAutomationService: Sendable {
    public let environment: KanameDesktopEnvironment
    public let runner: LocalCoreRunner?

    public init(
        environment: KanameDesktopEnvironment,
        runner: LocalCoreRunner? = nil
    ) {
        self.environment = environment
        self.runner = runner
    }

    /// Performs one bounded maintenance pass and records a local health
    /// heartbeat. A stale heartbeat therefore remains distinguishable from a
    /// successful pass after the local core disappears.
    @discardableResult
    public func runOnce() async -> DesktopAutomationServiceRunResult {
        guard environment.allowsAutomaticExecution else {
            recordHealth(state: "disabled")
            return .disabled
        }
        guard let runner else {
            recordHealth(state: "unavailable")
            return .unavailable
        }
        let loader = DesktopWorkflowRunHistoryLoader(
            inspection: DesktopWorkflowRunInspectionClient(transport: runner),
            library: DesktopWorkflowV2LibraryClient(transport: runner)
        )
        guard let snapshot = try? await loader.load(
            limit: 100, requestID: "automation-service:\(UUID().uuidString.lowercased())",
            attentionOnly: true
        ) else {
            recordHealth(state: "unavailable")
            return .unavailable
        }
        let application = await DesktopStandingEffectRules.applyStandingRulesDetailed(
            to: snapshot, runner: runner, environment: environment
        )
        if application.failedCount > 0 {
            recordHealth(state: "unavailable", advancedRuleCount: application.advanced.count)
            return .unavailable
        }
        recordHealth(state: "healthy", advancedRuleCount: application.advanced.count)
        return .healthy(advancedRuleCount: application.advanced.count)
    }

    private func recordHealth(state: String, advancedRuleCount: Int = 0) {
        let url = environment.runtimeDirectory.appendingPathComponent(
            "automation-service-health.json", isDirectory: false
        )
        let object: [String: Any] = [
            "schemaVersion": 1,
            "state": state,
            "channel": environment.channel.rawValue,
            "updatedAtUnixMillis": Int64(Date().timeIntervalSince1970 * 1_000),
            "advancedRuleCount": advancedRuleCount,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(
            at: environment.runtimeDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
