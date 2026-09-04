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
struct DesktopStandingEffectRule: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(workflowID)|\(connectorClass)|\(action)" }
    let workflowID: String
    let workflowName: String
    let connectorClass: String
    let action: String
    let createdAtUnixMillis: Int64

    var reference: String { "standing-rule:\(id)" }

    func matches(_ effect: DesktopWorkflowProjectedEffectAuthority, workflowID: String) -> Bool {
        self.workflowID == workflowID && connectorClass == effect.connectorClass && action == effect.action
    }
}

enum DesktopStandingEffectRules {
    private struct File: Codable {
        var rules: [DesktopStandingEffectRule]
    }

    /// Only narrow, reversible mailbox mutations may be granted standing
    /// authority (Candidate enablement ladder). Sending and trashing always
    /// wait for an explicit decision.
    static let standingEligibleActions: Set<String> = ["label", "archive", "mark-read", "draft"]

    /// Standing grants are never honoured on the Development channel, where
    /// external mutations are denied by policy anyway.
    static func isEligible(_ effect: DesktopWorkflowProjectedEffectAuthority, environment: KanameDesktopEnvironment = .current) -> Bool {
        environment.allowsExternalMutations && standingEligibleActions.contains(effect.action)
    }

    static func url(_ environment: KanameDesktopEnvironment = .current) -> URL {
        environment.applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("standing-rules.json")
    }

    static func load(_ environment: KanameDesktopEnvironment = .current) -> [DesktopStandingEffectRule] {
        guard let data = try? Data(contentsOf: url(environment)),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.rules
    }

    static func save(_ rules: [DesktopStandingEffectRule], _ environment: KanameDesktopEnvironment = .current) {
        let target = url(environment)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(rules: rules)) else { return }
        try? data.write(to: target, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    static func add(_ rule: DesktopStandingEffectRule, _ environment: KanameDesktopEnvironment = .current) {
        var rules = load(environment).filter { $0.id != rule.id }
        rules.append(rule)
        save(rules, environment)
    }

    static func remove(id: String, _ environment: KanameDesktopEnvironment = .current) {
        save(load(environment).filter { $0.id != id }, environment)
    }

    static func rule(for effect: DesktopWorkflowProjectedEffectAuthority, workflowID: String, _ environment: KanameDesktopEnvironment = .current) -> DesktopStandingEffectRule? {
        load(environment).first { $0.matches(effect, workflowID: workflowID) }
    }

    /// Approves every proposed effect in the snapshot that a standing rule
    /// covers and continues its run. Returns the names of workflows advanced.
    static func applyStandingRules(to snapshot: DesktopWorkflowRunHistorySnapshot, runner: LocalCoreRunner) async -> [String] {
        let rules = load()
        guard !rules.isEmpty, KanameDesktopEnvironment.current.allowsExternalMutations else { return [] }
        var advanced: [String] = []
        for item in snapshot.runs {
            let run = item.run
            let proposed = run.effectAuthorities.filter { $0.status == "proposed" }
            guard !proposed.isEmpty else { continue }
            var approvedAny = false
            for effect in proposed where isEligible(effect) {
                guard let rule = rules.first(where: { $0.matches(effect, workflowID: run.workflowID) }) else { continue }
                do {
                    _ = try await runner.authorizeWorkflowEffect(
                        effectID: effect.effectID,
                        approvalID: effect.approvalID,
                        approvalFingerprint: effect.approvalFingerprint,
                        approve: true,
                        standingRuleReference: rule.reference
                    )
                    approvedAny = true
                } catch {
                    continue
                }
            }
            if approvedAny {
                _ = try? await runner.startWorkflowRun(workflowID: run.workflowID, revisionID: run.revisionID, runID: run.runID)
                advanced.append(item.graph?.name ?? run.workflowID)
            }
        }
        return advanced
    }
}
