import Foundation

// MARK: - Preview-derived standing authority

public enum DesktopWorkflowAuthorityEventKind: String, Codable, CaseIterable, Equatable, Sendable {
    case created
    case used
    case paused
    case resumed
    case revoked
    case expired
    case exhausted
}

public struct DesktopWorkflowAuthorityEventRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var grantID: String
    public var workflowID: String
    public var kind: DesktopWorkflowAuthorityEventKind
    public var detail: String
    public var recordedAtUnixMillis: Int64
}

public struct DesktopWorkflowAuthorityScopeSimulation: Equatable, Sendable {
    public var previewID: String
    public var workflowID: String
    public var connectorID: String
    public var effectKind: String
    public var accountIDs: [String]
    public var targetPredicates: [DesktopWorkflowPredicate]
    public var requiresManualRun: Bool
    public var maximumItemsPerExecution: Int
    public var maximumUses: Int?
    public var expiresAtUnixMillis: Int64?
    public var postcondition: String
    public var sourceTargetDigest: String
    public var findings: [String]

    public var canCreateGrant: Bool { findings.isEmpty }
}

// MARK: - Local content lifecycle

public enum DesktopWorkflowContentClass: String, Codable, CaseIterable, Equatable, Sendable {
    case triggerPayload
    case messageBody
    case attachment
    case modelTranscript
    case generatedArtifact
}

public enum DesktopWorkflowContentState: String, Codable, CaseIterable, Equatable, Sendable {
    case ordinary
    case unresolved
    case promoted
    case purged
}

public struct DesktopWorkflowContentRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(workflowID):\(artifactDigest)" }
    public var workflowID: String
    public var installationID: String?
    public var workItemID: String
    public var artifactDigest: String
    public var dataClass: DesktopWorkflowContentClass
    public var byteCount: Int
    public var state: DesktopWorkflowContentState
    public var retentionReason: String
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
}

public enum DesktopWorkflowPurgeMode: String, Codable, CaseIterable, Equatable, Sendable {
    case automaticSettlement
    case manual
}

public struct DesktopWorkflowPurgePlan: Equatable, Sendable {
    public var workflowID: String
    public var mode: DesktopWorkflowPurgeMode
    public var eligibleDigests: [String]
    public var eligibleBytes: Int
    public var retained: [String: String]
    public var evidenceDigest: String
}

public struct DesktopWorkflowPurgeReceiptRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var mode: DesktopWorkflowPurgeMode
    public var evidenceDigest: String
    public var removedDigests: [String]
    public var removedBytes: Int
    public var retainedCountsByReason: [String: Int]
    public var completedAtUnixMillis: Int64
}

// MARK: - Quiet operational status

public enum DesktopWorkflowOperationalStatusKind: String, Codable, CaseIterable, Equatable, Sendable {
    case triggerLag
    case authenticationExpired
    case resourceDrift
    case retentionFailure
    case unknownEffect
}

public enum DesktopWorkflowOperationalStatusLevel: String, Codable, CaseIterable, Equatable, Sendable {
    case informational
    case degraded
    case actionRequired

    var sortPriority: Int {
        switch self {
        case .informational: 0
        case .degraded: 1
        case .actionRequired: 2
        }
    }
}

public struct DesktopWorkflowOperationalStatusRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String?
    public var relatedID: String
    public var kind: DesktopWorkflowOperationalStatusKind
    public var level: DesktopWorkflowOperationalStatusLevel
    public var summary: String
    public var active: Bool
    public var firstObservedAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
}

// MARK: - Untrusted external content and deterministic action intent

public enum DesktopWorkflowContentTrust: String, Codable, CaseIterable, Equatable, Sendable {
    case trustedLocalPolicy
    case trustedUserConfiguration
    case untrustedExternalContent
}

public struct DesktopWorkflowExternalContentProvenance: Codable, Equatable, Identifiable, Sendable {
    public var id: String { digest }
    public var sourceID: String
    public var providerID: String?
    public var accountID: String?
    public var mediaType: String
    public var digest: String
    public var trust: DesktopWorkflowContentTrust

    public init(
        sourceID: String,
        providerID: String?,
        accountID: String?,
        mediaType: String,
        digest: String,
        trust: DesktopWorkflowContentTrust
    ) {
        self.sourceID = sourceID
        self.providerID = providerID
        self.accountID = accountID
        self.mediaType = mediaType
        self.digest = digest
        self.trust = trust
    }
}

public struct DesktopWorkflowActionIntent: Equatable, Sendable {
    public var workflowID: String
    public var workflowRevisionID: String
    public var configurationRevisionID: String?
    public var bindingRevisionID: String?
    public var connectorID: String
    public var effectKind: String
    public var accountID: String?
    public var structuredTargetDigest: String
    public var itemCount: Int
    public var manuallyInitiated: Bool
}

public enum DesktopWorkflowPermissionMonotonicity {
    public static func permits(callee: DesktopWorkflowPermissionEnvelope, within caller: DesktopWorkflowPermissionEnvelope) -> Bool {
        !callee.broadens(caller)
    }
}

public extension DesktopAppModel {
    var activeWorkflowOperationalStatuses: [DesktopWorkflowOperationalStatusRecord] {
        snapshot.operations.workflows.operationalStatuses.filter(\.active).sorted {
            ($0.level.sortPriority, $0.kind.rawValue, $0.relatedID)
                > ($1.level.sortPriority, $1.kind.rawValue, $1.relatedID)
        }
    }

    func simulateWorkflowAuthorityGrant(
        previewID: String,
        targetPredicates: [DesktopWorkflowPredicate],
        requiresManualRun: Bool,
        maximumItemsPerExecution: Int,
        maximumUses: Int? = nil,
        expiresAtUnixMillis: Int64? = nil,
        postcondition: String
    ) -> DesktopWorkflowAuthorityScopeSimulation? {
        guard let preview = snapshot.operations.workflows.effectPreviews.first(where: { $0.id == previewID }),
              let effect = snapshot.operations.workflows.effects.first(where: { $0.id == preview.effectID }),
              let item = snapshot.operations.workflows.workItems.first(where: { $0.id == effect.workItemID }),
              let accountID = preview.request.accountID else { return nil }
        var findings: [String] = []
        let timestamp = now()
        if effect.state != .proposed { findings.append("The source effect is no longer an unexecuted preview.") }
        if targetPredicates.isEmpty || targetPredicates.count > 32 {
            findings.append("Choose between one and 32 deterministic target predicates.")
        } else if !DesktopWorkflowStructuredValue.matches(targetPredicates, data: preview.structuredTarget) {
            findings.append("The proposed predicates do not match every field required by this exact preview.")
        }
        if maximumItemsPerExecution < preview.itemCount || maximumItemsPerExecution > 10_000 {
            findings.append("The item ceiling must cover this preview without exceeding 10,000 items.")
        }
        if maximumUses.map({ !(1...100_000).contains($0) }) == true {
            findings.append("The use limit must be between one and 100,000.")
        }
        if expiresAtUnixMillis.map({ $0 <= timestamp }) == true { findings.append("The expiry must be in the future.") }
        if postcondition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append("A deterministic provider postcondition is required.")
        }
        if preview.request.workflowID != item.workflowID { findings.append("The preview workflow linkage is stale.") }
        return DesktopWorkflowAuthorityScopeSimulation(
            previewID: previewID, workflowID: item.workflowID,
            connectorID: preview.connectorID, effectKind: preview.request.effectKind,
            accountIDs: [accountID], targetPredicates: targetPredicates,
            requiresManualRun: requiresManualRun,
            maximumItemsPerExecution: maximumItemsPerExecution,
            maximumUses: maximumUses, expiresAtUnixMillis: expiresAtUnixMillis,
            postcondition: String(postcondition.prefix(8_192)),
            sourceTargetDigest: preview.structuredTargetDigest, findings: findings
        )
    }

    @discardableResult
    func createWorkflowAuthorityGrant(from simulation: DesktopWorkflowAuthorityScopeSimulation) -> String? {
        guard simulation.canCreateGrant,
              let refreshed = simulateWorkflowAuthorityGrant(
                  previewID: simulation.previewID,
                  targetPredicates: simulation.targetPredicates,
                  requiresManualRun: simulation.requiresManualRun,
                  maximumItemsPerExecution: simulation.maximumItemsPerExecution,
                  maximumUses: simulation.maximumUses,
                  expiresAtUnixMillis: simulation.expiresAtUnixMillis,
                  postcondition: simulation.postcondition
              ), refreshed == simulation else { return nil }
        return createWorkflowAuthorityGrant(
            workflowID: simulation.workflowID, connectorID: simulation.connectorID,
            effectKind: simulation.effectKind, accountIDs: simulation.accountIDs,
            targetPredicates: simulation.targetPredicates,
            requiresManualRun: simulation.requiresManualRun,
            maximumItemsPerExecution: simulation.maximumItemsPerExecution,
            postcondition: simulation.postcondition,
            expiresAtUnixMillis: simulation.expiresAtUnixMillis,
            maximumUses: simulation.maximumUses,
            sourcePreviewID: simulation.previewID,
            sourceTargetDigest: simulation.sourceTargetDigest
        )
    }

    func workflowActionIntent(effectID: String) -> DesktopWorkflowActionIntent? {
        guard let effect = snapshot.operations.workflows.effects.first(where: { $0.id == effectID }),
              let preview = snapshot.operations.workflows.effectPreviews.first(where: { $0.effectID == effectID }),
              let run = snapshot.operations.workflows.runs.first(where: { $0.id == effect.runID }),
              let item = snapshot.operations.workflows.workItems.first(where: { $0.id == effect.workItemID }) else { return nil }
        let installation = item.installationID.flatMap { id in
            snapshot.operations.workflows.installations.first { $0.id == id }
        }
        return DesktopWorkflowActionIntent(
            workflowID: item.workflowID, workflowRevisionID: run.workflowRevisionID,
            configurationRevisionID: installation?.currentConfigurationRevisionID,
            bindingRevisionID: installation?.currentBindingRevisionID,
            connectorID: preview.connectorID, effectKind: preview.request.effectKind,
            accountID: preview.request.accountID,
            structuredTargetDigest: preview.structuredTargetDigest,
            itemCount: preview.itemCount, manuallyInitiated: preview.request.manuallyInitiated
        )
    }

    func validatesWorkflowActionIntent(effectID: String, candidate: DesktopWorkflowActionIntent) -> Bool {
        workflowActionIntent(effectID: effectID) == candidate
    }

    @discardableResult
    func expireWorkflowAuthorityGrants() -> Int {
        let timestamp = now()
        let expired = snapshot.operations.workflows.authorityGrants.filter { grant in
            grant.state == .active && (
                grant.expiresAtUnixMillis.map { $0 <= timestamp } == true
                    || grant.maximumUses.map { grant.useCount >= $0 } == true
            )
        }
        guard !expired.isEmpty else { return 0 }
        let ids = Set(expired.map(\.id))
        guard mutate({ state in
            for index in state.operations.workflows.authorityGrants.indices
                where ids.contains(state.operations.workflows.authorityGrants[index].id) {
                let grant = state.operations.workflows.authorityGrants[index]
                let exhausted = grant.maximumUses.map { grant.useCount >= $0 } ?? false
                state.operations.workflows.authorityGrants[index].state = .expired
                state.operations.workflows.authorityEvents.append(.init(
                    id: UUID().uuidString.lowercased(), grantID: grant.id, workflowID: grant.workflowID,
                    kind: exhausted ? .exhausted : .expired,
                    detail: exhausted ? "The configured use limit was reached." : "The configured expiry was reached.",
                    recordedAtUnixMillis: timestamp
                ))
            }
        }) else { return 0 }
        return expired.count
    }

    @discardableResult
    func promoteWorkflowContent(workflowID: String, artifactDigest: String, reason: String) -> Bool {
        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanReason.isEmpty, cleanReason.utf8.count <= 2_048 else { return false }
        let timestamp = now()
        return mutateRecord(at: \.operations.workflows.contentRecords, id: "\(workflowID):\(artifactDigest)") { record in
            guard record.state != .purged else { return }
            record.state = .promoted
            record.retentionReason = String(cleanReason.prefix(2_048))
            record.updatedAtUnixMillis = timestamp
        }
    }

    func previewWorkflowPurge(workflowID: String, mode: DesktopWorkflowPurgeMode) -> DesktopWorkflowPurgePlan? {
        let records = snapshot.operations.workflows.contentRecords.filter { $0.workflowID == workflowID && $0.state != .purged }
        guard !records.isEmpty else { return nil }
        let workItems = Dictionary(uniqueKeysWithValues: snapshot.operations.workflows.workItems.map { ($0.id, $0) })
        let unresolvedEffectDigests = Set(snapshot.operations.workflows.effects.filter {
            $0.state == .executing || $0.state == .outcomeUnknown || $0.state == .awaitingApproval || $0.state == .approved
        }.flatMap { [$0.contentDigest] + $0.attachmentDigests })
        var eligible: [DesktopWorkflowContentRecord] = []
        var retained: [String: String] = [:]
        for record in records {
            let reason: String?
            if record.state == .promoted {
                reason = "Explicitly promoted durable artifact."
            } else if unresolvedEffectDigests.contains(record.artifactDigest) {
                reason = "Required to reconcile an unresolved external effect."
            } else if workItems[record.workItemID]?.state.isHistorical != true {
                reason = "Its workflow work item has not settled."
            } else if mode == .automaticSettlement && !automaticPurgeEnabled(for: record) {
                reason = "The active retention policy requires explicit removal."
            } else {
                reason = nil
            }
            if let reason { retained[record.artifactDigest] = reason } else { eligible.append(record) }
        }
        let digests = Array(Set(eligible.map(\.artifactDigest))).sorted()
        let bytes = Dictionary(grouping: eligible, by: \.artifactDigest).values.compactMap { $0.first?.byteCount }.reduce(0, +)
        let evidence = purgeEvidenceDigest(workflowID: workflowID, mode: mode, eligible: digests, retained: retained)
        return DesktopWorkflowPurgePlan(
            workflowID: workflowID, mode: mode, eligibleDigests: digests,
            eligibleBytes: bytes, retained: retained, evidenceDigest: evidence
        )
    }

    @discardableResult
    func executeWorkflowPurge(_ plan: DesktopWorkflowPurgePlan, storage: DesktopWorkflowStorage) throws -> String? {
        guard previewWorkflowPurge(workflowID: plan.workflowID, mode: plan.mode) == plan else { return nil }
        let removed = try storage.removeArtifacts(sha256s: Set(plan.eligibleDigests))
        guard Set(removed.map(\.sha256)) == Set(plan.eligibleDigests) else { return nil }
        let timestamp = now()
        let receipt = DesktopWorkflowPurgeReceiptRecord(
            id: UUID().uuidString.lowercased(), workflowID: plan.workflowID, mode: plan.mode,
            evidenceDigest: plan.evidenceDigest, removedDigests: plan.eligibleDigests,
            removedBytes: removed.reduce(0) { $0 + $1.byteCount },
            retainedCountsByReason: Dictionary(grouping: plan.retained.values, by: { $0 }).mapValues(\.count),
            completedAtUnixMillis: timestamp
        )
        guard mutate({ state in
            for index in state.operations.workflows.contentRecords.indices
                where state.operations.workflows.contentRecords[index].workflowID == plan.workflowID
                    && plan.eligibleDigests.contains(state.operations.workflows.contentRecords[index].artifactDigest) {
                state.operations.workflows.contentRecords[index].state = .purged
                state.operations.workflows.contentRecords[index].retentionReason = "Removed under verified \(plan.mode.rawValue) purge."
                state.operations.workflows.contentRecords[index].updatedAtUnixMillis = timestamp
            }
            for index in state.operations.workflows.artifactRoles.indices
                where state.operations.workflows.artifactRoles[index].workflowID == plan.workflowID
                    && plan.eligibleDigests.contains(state.operations.workflows.artifactRoles[index].artifactDigest) {
                state.operations.workflows.artifactRoles[index].active = false
            }
            state.operations.workflows.purgeReceipts.append(receipt)
            state.appendAudit(
                domain: "workflow-retention", action: "purge", target: plan.workflowID,
                state: .completed,
                detail: "Removed \(receipt.removedDigests.count) eligible artifact(s) and retained \(plan.retained.count) by policy.",
                recordedAtUnixMillis: timestamp
            )
        }) else { return nil }
        return receipt.id
    }

    @discardableResult
    func recordWorkflowOperationalStatus(
        workflowID: String?, relatedID: String, kind: DesktopWorkflowOperationalStatusKind,
        level: DesktopWorkflowOperationalStatusLevel, summary: String, active: Bool = true
    ) -> Bool {
        guard !relatedID.isEmpty, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let id = "\(kind.rawValue):\(relatedID)"
        let timestamp = now()
        let prior = snapshot.operations.workflows.operationalStatuses.first { $0.id == id }
        let record = DesktopWorkflowOperationalStatusRecord(
            id: id, workflowID: workflowID, relatedID: relatedID, kind: kind, level: level,
            summary: String(summary.prefix(2_048)), active: active,
            firstObservedAtUnixMillis: prior?.firstObservedAtUnixMillis ?? timestamp,
            updatedAtUnixMillis: timestamp
        )
        return mutate { state in
            state.operations.workflows.operationalStatuses.removeAll { $0.id == record.id }
            state.operations.workflows.operationalStatuses.append(record)
        }
    }

    @discardableResult
    func recoverInterruptedWorkflowBatch(runID: String, stepID: String) -> Int {
        let affected = snapshot.operations.workflows.batchItems.filter {
            $0.runID == runID && $0.stepID == stepID && $0.state == .running
        }.map(\.id)
        guard !affected.isEmpty else { return 0 }
        let timestamp = now()
        guard mutate({ state in
            for index in state.operations.workflows.batchItems.indices where affected.contains(state.operations.workflows.batchItems[index].id) {
                state.operations.workflows.batchItems[index].state = .unknown
                state.operations.workflows.batchItems[index].errorSummary = "Execution was interrupted; reconcile before retrying."
                state.operations.workflows.batchItems[index].completedAtUnixMillis = timestamp
            }
        }) else { return 0 }
        return affected.count
    }

    @discardableResult
    func retryFailedWorkflowBatchItems(ids: Set<String>) -> Bool {
        guard !ids.isEmpty,
              snapshot.operations.workflows.batchItems.filter({ ids.contains($0.id) }).allSatisfy({ $0.state == .failed }) else {
            return false
        }
        return mutate { state in
            for index in state.operations.workflows.batchItems.indices where ids.contains(state.operations.workflows.batchItems[index].id) {
                state.operations.workflows.batchItems[index].state = .queued
                state.operations.workflows.batchItems[index].errorSummary = nil
                state.operations.workflows.batchItems[index].completedAtUnixMillis = nil
            }
        }
    }

    @discardableResult
    func reconcileUnknownWorkflowBatchItem(
        id: String, outcomeKnown: Bool, succeeded: Bool, outputDigest: String? = nil, detail: String
    ) -> Bool {
        guard snapshot.operations.workflows.batchItems.contains(where: { $0.id == id && $0.state == .unknown }),
              outputDigest.map({ $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }) ?? true else {
            return false
        }
        let timestamp = now()
        return mutateRecord(at: \.operations.workflows.batchItems, id: id) { item in
            item.state = outcomeKnown ? (succeeded ? .succeeded : .failed) : .unknown
            item.outputDigest = succeeded ? outputDigest : nil
            item.errorSummary = succeeded ? nil : String(detail.prefix(2_048))
            item.completedAtUnixMillis = timestamp
        }
    }

    private func automaticPurgeEnabled(for record: DesktopWorkflowContentRecord) -> Bool {
        let installation = record.installationID.flatMap { id in
            snapshot.operations.workflows.installations.first { $0.id == id }
        } ?? workflowInstallations(workflowID: record.workflowID).first
        guard let installation,
              let policy = snapshot.operations.workflows.retentionPolicyRevisions.first(where: {
                  $0.id == installation.currentRetentionPolicyRevisionID
              })?.policy else { return false }
        return policy.settledContent == .purgeOrdinaryContent
    }

    private func purgeEvidenceDigest(
        workflowID: String, mode: DesktopWorkflowPurgeMode,
        eligible: [String], retained: [String: String]
    ) -> String {
        let retainedText = retained.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        return DesktopWorkflowStructuredValue.digest(
            Data("\(workflowID)|\(mode.rawValue)|\(eligible.joined(separator: ","))|\(retainedText)".utf8)
        )
    }
}
