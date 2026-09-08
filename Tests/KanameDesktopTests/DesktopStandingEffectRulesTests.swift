import Foundation
import Testing
import KanameConnectivity
@testable import KanameDesktop
@testable import KanameWorkflowHost

struct DesktopStandingEffectRulesTests {
    @Test("standing authority is scoped to revision, account binding, and target")
    func exactScopeOnly() {
        let target = String(repeating: "a", count: 64)
        let effect = DesktopWorkflowProjectedEffectAuthority(
            effectID: "effect-1", nodeID: "node-1", connectorClass: "mail", action: "label",
            accountBindingID: "account-1", destinationFingerprint: target,
            inputDigest: "input", intentDigest: "intent", previewDigest: "preview",
            idempotencyKey: "idempotency", approvalID: "approval", approvalFingerprint: Data(),
            status: "proposed", consequence: "reversible", reversible: true,
            expiresAtUnixMillis: 100_000, grantID: nil, actorID: nil, deviceID: nil,
            proposedAtUnixMillis: 1, authorizedAtUnixMillis: nil, proposedStorePosition: 1,
            authorizedStorePosition: nil, dispatch: nil, reconciliation: nil
        )
        let rule = DesktopStandingEffectRule(
            workflowID: "workflow-1", workflowName: "Triage", revisionID: "revision-1",
            accountBindingID: "account-1", connectorClass: "mail", action: "label",
            destinationFingerprint: target, createdAtUnixMillis: 1
        )

        #expect(rule.matches(effect, workflowID: "workflow-1", revisionID: "revision-1"))
        #expect(!rule.matches(effect, workflowID: "workflow-1", revisionID: "revision-2"))
        #expect(!rule.matches(
            effectWith(effect, accountBindingID: "account-2"),
            workflowID: "workflow-1", revisionID: "revision-1"
        ))
        #expect(!rule.matches(
            effectWith(effect, destinationFingerprint: String(repeating: "b", count: 64)),
            workflowID: "workflow-1", revisionID: "revision-1"
        ))
        let accountRule = DesktopStandingEffectRule(
            workflowID: "workflow-1", workflowName: "Triage", revisionID: "revision-1",
            accountBindingID: "account-1", connectorClass: "mail", action: "label",
            scope: .account, createdAtUnixMillis: 1
        )
        #expect(accountRule.matches(
            effectWith(effect, destinationFingerprint: String(repeating: "b", count: 64)),
            workflowID: "workflow-1", revisionID: "revision-1"
        ))
    }

    @Test("incomplete or legacy rules are discarded on persistence")
    func incompleteRulesAreDiscarded() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-standing-rules")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = KanameDesktopEnvironment(
            channel: .candidate, applicationSupportDirectory: root
        )
        let valid = DesktopStandingEffectRule(
            workflowID: "workflow-1", workflowName: "Triage", revisionID: "revision-1",
            accountBindingID: "account-1", connectorClass: "mail", action: "archive",
            destinationFingerprint: String(repeating: "c", count: 64), createdAtUnixMillis: 1
        )
        let incomplete = DesktopStandingEffectRule(
            workflowID: "workflow-1", workflowName: "Triage", connectorClass: "mail",
            action: "archive", createdAtUnixMillis: 1
        )
        DesktopStandingEffectRules.save([valid, incomplete], environment)
        #expect(DesktopStandingEffectRules.load(environment) == [valid])
    }

    @Test("authorized effects resume only from their persisted standing rule")
    func authorizedRecoveryRequiresStandingReference() {
        let target = String(repeating: "d", count: 64)
        let proposed = DesktopWorkflowProjectedEffectAuthority(
            effectID: "effect-recovery", nodeID: "node-1", connectorClass: "mail", action: "label",
            accountBindingID: "account-1", destinationFingerprint: target,
            inputDigest: "input", intentDigest: "intent", previewDigest: "preview",
            idempotencyKey: "idempotency", approvalID: "approval", approvalFingerprint: Data(),
            status: "proposed", consequence: "reversible", reversible: true,
            expiresAtUnixMillis: 100_000, grantID: nil, actorID: nil, deviceID: nil,
            proposedAtUnixMillis: 1, authorizedAtUnixMillis: nil, proposedStorePosition: 1,
            authorizedStorePosition: nil, dispatch: nil, reconciliation: nil
        )
        let rule = DesktopStandingEffectRule(
            workflowID: "workflow-1", workflowName: "Triage", revisionID: "revision-1",
            accountBindingID: "account-1", connectorClass: "mail", action: "label",
            destinationFingerprint: target, createdAtUnixMillis: 1
        )
        let authorized = effectWith(
            proposed,
            status: "authorized",
            standingRuleReference: rule.reference
        )
        #expect(DesktopStandingEffectRules.shouldResumeAuthorizedEffect(
            authorized, rule: rule, workflowID: "workflow-1", revisionID: "revision-1"
        ))
        #expect(!DesktopStandingEffectRules.shouldResumeAuthorizedEffect(
            effectWith(authorized, standingRuleReference: "standing-rule:other"),
            rule: rule, workflowID: "workflow-1", revisionID: "revision-1"
        ))
        #expect(!DesktopStandingEffectRules.shouldResumeAuthorizedEffect(
            effectWith(authorized, standingRuleReference: .some(nil)),
            rule: rule, workflowID: "workflow-1", revisionID: "revision-1"
        ))
    }

    private func effectWith(
        _ effect: DesktopWorkflowProjectedEffectAuthority,
        accountBindingID: String? = nil,
        destinationFingerprint: String? = nil,
        status: String? = nil,
        standingRuleReference: String?? = nil
    ) -> DesktopWorkflowProjectedEffectAuthority {
        DesktopWorkflowProjectedEffectAuthority(
            effectID: effect.effectID, nodeID: effect.nodeID, connectorClass: effect.connectorClass,
            action: effect.action, accountBindingID: accountBindingID ?? effect.accountBindingID,
            destinationFingerprint: destinationFingerprint ?? effect.destinationFingerprint,
            inputDigest: effect.inputDigest, intentDigest: effect.intentDigest,
            previewDigest: effect.previewDigest, idempotencyKey: effect.idempotencyKey,
            approvalID: effect.approvalID, approvalFingerprint: effect.approvalFingerprint,
            standingRuleReference: standingRuleReference ?? effect.standingRuleReference,
            status: status ?? effect.status, consequence: effect.consequence, reversible: effect.reversible,
            expiresAtUnixMillis: effect.expiresAtUnixMillis, grantID: effect.grantID,
            actorID: effect.actorID, deviceID: effect.deviceID,
            proposedAtUnixMillis: effect.proposedAtUnixMillis,
            authorizedAtUnixMillis: effect.authorizedAtUnixMillis,
            proposedStorePosition: effect.proposedStorePosition,
            authorizedStorePosition: effect.authorizedStorePosition,
            dispatch: effect.dispatch, reconciliation: effect.reconciliation
        )
    }
}
