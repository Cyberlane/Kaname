import Foundation
import KanameConnectivity
import KanameDesktop
import KanameLocalCore

/// Owner-granted standing approvals for workflow effects: "always allow this
/// action on this connector for this workflow". A matching proposed effect is
/// approved automatically and the run continues, with the rule's identity
/// recorded as the approval's standing-rule reference so the journal shows
/// that no human clicked. Rules live in Workflows/standing-rules.json and can
/// be removed from Run history at any time.
public enum DesktopStandingEffectScope: String, Codable, Equatable, Sendable {
    case destination
    case account
}

public struct DesktopStandingEffectRule: Codable, Equatable, Identifiable, Sendable {
    /// The identity includes every scope component. Removing or changing a
    /// workflow revision, account binding, or target creates a different rule.
    public var id: String {
        "\(workflowID)|\(revisionID)|\(accountBindingID)|\(connectorClass)|\(action)|\(scope.rawValue)|\(destinationFingerprint)"
    }
    public let workflowID: String
    public let workflowName: String
    public let revisionID: String
    public let accountBindingID: String
    public let connectorClass: String
    public let action: String
    public let scope: DesktopStandingEffectScope
    public let destinationFingerprint: String
    public let createdAtUnixMillis: Int64

    var isValid: Bool {
        !workflowID.isEmpty && !revisionID.isEmpty && !accountBindingID.isEmpty
            && !connectorClass.isEmpty && !action.isEmpty
            && (scope == .account || !destinationFingerprint.isEmpty)
    }

    public var reference: String { "standing-rule:\(id)" }

    public init(
        workflowID: String,
        workflowName: String,
        revisionID: String = "",
        accountBindingID: String = "",
        connectorClass: String,
        action: String,
        scope: DesktopStandingEffectScope = .destination,
        destinationFingerprint: String = "",
        createdAtUnixMillis: Int64
    ) {
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.revisionID = revisionID
        self.accountBindingID = accountBindingID
        self.connectorClass = connectorClass
        self.action = action
        self.scope = scope
        // Account-wide grants intentionally have no destination component.
        // This keeps their identity stable as new conversations arrive and
        // makes the broader scope explicit in the persisted record.
        self.destinationFingerprint = scope == .account ? "" : destinationFingerprint
        self.createdAtUnixMillis = createdAtUnixMillis
    }

    public func matches(_ effect: DesktopWorkflowProjectedEffectAuthority, workflowID: String, revisionID: String) -> Bool {
        self.workflowID == workflowID
            && self.revisionID == revisionID
            && !revisionID.isEmpty
            && accountBindingID == effect.accountBindingID
            && !accountBindingID.isEmpty
            && connectorClass == effect.connectorClass
            && action == effect.action
            && (scope == .account || destinationFingerprint == effect.destinationFingerprint)
            && (scope == .account || !destinationFingerprint.isEmpty)
    }
}

public enum DesktopStandingEffectRules {
    public struct ApplicationResult: Equatable, Sendable {
        public let advanced: [String]
        public let failedCount: Int

        public init(advanced: [String], failedCount: Int) {
            self.advanced = advanced
            self.failedCount = failedCount
        }
    }

    private struct File: Codable {
        var rules: [DesktopStandingEffectRule]
    }

    /// Only narrow, reversible mailbox mutations may be granted standing
    /// authority (Candidate enablement ladder). Sending and trashing always
    /// wait for an explicit decision.
    public static let standingEligibleActions: Set<String> = ["label", "archive", "mark-read", "draft"]

    /// Standing grants are never honoured on the Development channel, where
    /// external mutations are denied by policy anyway.
    public static func isEligible(_ effect: DesktopWorkflowProjectedEffectAuthority, environment: KanameDesktopEnvironment = .current) -> Bool {
        environment.allowsExternalMutations
            && standingEligibleActions.contains(effect.action)
            && !effect.accountBindingID.isEmpty
            && !effect.destinationFingerprint.isEmpty
    }

    public static func url(_ environment: KanameDesktopEnvironment = .current) -> URL {
        environment.applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("standing-rules.json")
    }

    public static func load(_ environment: KanameDesktopEnvironment = .current) -> [DesktopStandingEffectRule] {
        guard let data = try? Data(contentsOf: url(environment)),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        // Invalid or pre-scope rules are discarded on read. This makes an
        // older grant fail closed rather than silently broaden its authority.
        return file.rules.filter(\.isValid)
    }

    public static func save(_ rules: [DesktopStandingEffectRule], _ environment: KanameDesktopEnvironment = .current) {
        let target = url(environment)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(rules: rules.filter(\.isValid))) else { return }
        try? data.write(to: target, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    public static func add(_ rule: DesktopStandingEffectRule, _ environment: KanameDesktopEnvironment = .current) {
        guard rule.isValid else { return }
        var rules = load(environment).filter { $0.id != rule.id }
        rules.append(rule)
        save(rules, environment)
    }

    public static func remove(id: String, _ environment: KanameDesktopEnvironment = .current) {
        save(load(environment).filter { $0.id != id }, environment)
    }

    public static func rule(for effect: DesktopWorkflowProjectedEffectAuthority, workflowID: String, revisionID: String, _ environment: KanameDesktopEnvironment = .current) -> DesktopStandingEffectRule? {
        load(environment).first { $0.matches(effect, workflowID: workflowID, revisionID: revisionID) }
    }

    /// An authorized effect may be resumed automatically only when its
    /// durable resolution names the exact persisted standing rule. A matching
    /// target alone is insufficient because a one-off owner approval has the
    /// same target fields but must remain under explicit user control.
    static func shouldResumeAuthorizedEffect(
        _ effect: DesktopWorkflowProjectedEffectAuthority,
        rule: DesktopStandingEffectRule,
        workflowID: String,
        revisionID: String
    ) -> Bool {
        effect.status == "authorized"
            && effect.standingRuleReference == rule.reference
            && rule.matches(effect, workflowID: workflowID, revisionID: revisionID)
    }

    /// Approves every proposed effect in the snapshot that a standing rule
    /// covers and continues its run. Returns the names of workflows advanced.
    public static func applyStandingRules(
        to snapshot: DesktopWorkflowRunHistorySnapshot,
        runner: LocalCoreRunner,
        environment: KanameDesktopEnvironment = .current
    ) async -> [String] {
        await applyStandingRulesDetailed(to: snapshot, runner: runner, environment: environment).advanced
    }

    public static func applyStandingRulesDetailed(
        to snapshot: DesktopWorkflowRunHistorySnapshot,
        runner: LocalCoreRunner,
        environment: KanameDesktopEnvironment = .current
    ) async -> ApplicationResult {
        let rules = load(environment)
        guard !rules.isEmpty, environment.allowsExternalMutations else {
            return ApplicationResult(advanced: [], failedCount: 0)
        }
        var advanced: [String] = []
        var failedCount = 0
        for item in snapshot.runs {
            let run = item.run
            let attention = run.effectAuthorities.filter {
                ["proposed", "authorized"].contains($0.status)
            }
            guard !attention.isEmpty else { continue }
            var shouldStart = false
            for effect in attention where isEligible(effect, environment: environment) {
                guard let rule = rules.first(where: {
                    $0.matches(effect, workflowID: run.workflowID, revisionID: run.revisionID)
                }) else { continue }
                if shouldResumeAuthorizedEffect(
                    effect, rule: rule, workflowID: run.workflowID, revisionID: run.revisionID
                ) {
                    shouldStart = true
                    continue
                }
                guard effect.status == "proposed" else { continue }
                do {
                    _ = try await runner.authorizeWorkflowEffect(
                        effectID: effect.effectID,
                        approvalID: effect.approvalID,
                        approvalFingerprint: effect.approvalFingerprint,
                        approve: true,
                        standingRuleReference: rule.reference
                    )
                    shouldStart = true
                } catch {
                    failedCount += 1
                    continue
                }
            }
            if shouldStart {
                do {
                    _ = try await runner.startWorkflowRun(
                        workflowID: run.workflowID, revisionID: run.revisionID, runID: run.runID
                    )
                    advanced.append(item.graph?.name ?? run.workflowID)
                } catch {
                    failedCount += 1
                }
            }
        }
        return ApplicationResult(advanced: advanced, failedCount: failedCount)
    }
}
