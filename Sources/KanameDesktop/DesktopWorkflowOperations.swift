import Foundation

public enum DesktopWorkflowOperationalHealth: String, Codable, CaseIterable, Equatable, Sendable {
    case unknown
    case healthy
    case degraded
    case paused
    case actionRequired

    public var label: String {
        switch self {
        case .unknown: "Not checked"
        case .healthy: "Healthy"
        case .degraded: "Degraded"
        case .paused: "Paused"
        case .actionRequired: "Action required"
        }
    }
}

public struct DesktopWorkflowTriggerHealthRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bindingID }
    public var bindingID: String
    public var state: DesktopWorkflowOperationalHealth
    public var lastAttemptAtUnixMillis: Int64?
    public var lastSuccessAtUnixMillis: Int64?
    public var nextAttemptAtUnixMillis: Int64?
    public var consecutiveFailures: Int
    public var errorCode: String?
    public var errorSummary: String?
    public var accountID: String?
    public var cursorLagEstimate: Int?
    public var authenticationRequired: Bool
}

public enum DesktopWorkflowOwnershipMode: String, Codable, CaseIterable, Equatable, Sendable {
    case sharedObservation
    case exclusive
    case protected

    public var label: String {
        switch self {
        case .sharedObservation: "Shared observation"
        case .exclusive: "Exclusive owner"
        case .protected: "Protected from other workflows"
        }
    }
}

public struct DesktopWorkflowOwnershipPolicyRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var accountID: String
    public var sourceFilter: String
    public var mode: DesktopWorkflowOwnershipMode
    public var priority: Int
    public var enabled: Bool
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
}

public struct DesktopWorkflowOwnershipClaimRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var workItemID: String?
    public var accountID: String
    public var conversationID: String
    public var mode: DesktopWorkflowOwnershipMode
    public var acquiredAtUnixMillis: Int64
    public var releasedAtUnixMillis: Int64?
    public var overrideReason: String?
}

public enum DesktopWorkflowExtensionTrust: String, Codable, Equatable, Sendable {
    case localDigest
    case signed
    case kanameBuiltIn
}

public struct DesktopWorkflowConnectorInstallationRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(connectorID)@\(version)" }
    public var connectorID: String
    public var name: String
    public var version: String
    public var packageDigest: String
    public var executableDigest: String
    public var designatedRequirement: String?
    public var effectKinds: [String]
    public var allowedHosts: [String]
    public var secretSlots: [String]
    public var trust: DesktopWorkflowExtensionTrust
    public var enabled: Bool
    public var qualified: Bool
    public var installedAtUnixMillis: Int64
    public var lastQualifiedAtUnixMillis: Int64?
}

public struct DesktopWorkflowConnectorBindingRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var connectorID: String
    public var accountID: String?
    public var secretReferences: [String: String]
    public var grantedHosts: [String]
    public var grantedEffectKinds: [String]
    public var enabled: Bool
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
}

public enum DesktopWorkflowQualificationOutcome: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case needsReview
}

public struct DesktopWorkflowQualificationAssertionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var label: String
    public var passed: Bool
    public var detail: String
}

public struct DesktopWorkflowQualificationRunRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var componentID: String
    public var componentVersion: String
    public var fixtureName: String
    public var artifactDigests: [String]
    public var stateDigest: String?
    public var contextDigest: String?
    public var outputDigest: String?
    public var outputArtifactDigests: [String]
    public var assertions: [DesktopWorkflowQualificationAssertionRecord]
    public var outcome: DesktopWorkflowQualificationOutcome
    public var elapsedMilliseconds: Int64
    public var executedAtUnixMillis: Int64
}

public struct DesktopWorkflowRendererInstallationRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(rendererID)@\(version)" }
    public var rendererID: String
    public var name: String
    public var version: String
    public var packageDigest: String
    public var mediaTypes: [String]
    public var supportsRecalculation: Bool
    public var supportsRangeSelection: Bool
    public var enabled: Bool
    public var qualified: Bool
    public var installedAtUnixMillis: Int64
}

public struct DesktopWorkflowRenderReceiptRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var rendererID: String
    public var workflowID: String
    public var workItemID: String
    public var sourceArtifactDigest: String
    public var previewArtifactDigests: [String]
    public var recalculated: Bool
    public var selections: [String]
    public var findings: [DesktopWorkflowQualificationAssertionRecord]
    public var outcome: DesktopWorkflowQualificationOutcome
    public var createdAtUnixMillis: Int64
}

public struct DesktopWorkflowSubflowReference: Codable, Equatable, Identifiable, Sendable {
    public var id: String { subflowID }
    public var subflowID: String
    public var version: String
    public var inputSchema: String
    public var outputSchema: String

    public static func pinned(
        subflowID: String,
        version: String,
        inputSchema: String,
        outputSchema: String
    ) -> Self {
        Self(
            subflowID: subflowID, version: version,
            inputSchema: inputSchema, outputSchema: outputSchema
        )
    }
}

public struct DesktopWorkflowSubflowRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(subflowID)@\(version)" }
    public var subflowID: String
    public var name: String
    public var summary: String
    public var version: String
    public var manifestDigest: String
    public var inputSchema: String
    public var outputSchema: String
    public var permissions: DesktopWorkflowPermissionEnvelope
    public var steps: [DesktopWorkflowStepDefinition]
    public var enabled: Bool
    public var installedAtUnixMillis: Int64
}

public struct DesktopWorkflowStudioDraftRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var name: String
    public var summary: String
    public var icon: String
    public var version: String
    public var triggerKinds: [DesktopWorkflowTriggerKind]
    public var steps: [DesktopWorkflowStepDefinition]
    public var permissions: DesktopWorkflowPermissionEnvelope
    public var subflows: [DesktopWorkflowSubflowReference]
    public var validationSummary: String?
    public var canvasPositions: [DesktopWorkflowCanvasNodePosition]? = nil
    public var manifestMetadata: DesktopWorkflowStudioManifestMetadata? = nil
    public var undoHistory: [DesktopWorkflowStudioSnapshot]? = nil
    public var redoHistory: [DesktopWorkflowStudioSnapshot]? = nil
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
}

public struct DesktopWorkflowScheduleBindingRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var spec: DesktopScheduleSpec
    public var timeZoneIdentifier: String
    public var missedRunPolicy: DesktopAutomationRule.MissedRunPolicy
    public var enabled: Bool
    public var nextRunAtUnixMillis: Int64?
    public var lastScheduledAtUnixMillis: Int64?
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
}

public enum DesktopWorkflowMigrationStage: String, Codable, CaseIterable, Equatable, Sendable {
    case observeOnly
    case shadow
    case draftOnly
    case approvedEffects
    case standingAuthority
    case legacyRetired

    public var label: String {
        switch self {
        case .observeOnly: "Observe only"
        case .shadow: "Shadow comparison"
        case .draftOnly: "Draft only"
        case .approvedEffects: "Approved effects"
        case .standingAuthority: "Standing authority"
        case .legacyRetired: "Legacy retired"
        }
    }
}

public struct DesktopWorkflowMigrationAssessmentRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var stage: DesktopWorkflowMigrationStage
    public var requiredScenarioIDs: [String]
    public var passedScenarioIDs: [String]
    public var blockingFindings: [String]
    public var legacyOutputDigest: String?
    public var kanameOutputDigest: String?
    public var workflowRevisionID: String? = nil
    public var manifestDigest: String? = nil
    public var installationID: String? = nil
    public var dependencyLockRevisionID: String? = nil
    public var dependencyLockDigest: String? = nil
    public var fixtureSuiteID: String? = nil
    public var fixtureSuiteDigest: String? = nil
    public var comparisonEvidenceIDs: [String]? = nil
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
}

public enum DesktopWorkflowOwnershipDecision: Equatable, Sendable {
    case acquired(claimID: String)
    case shared(claimID: String, otherWorkflowIDs: [String])
    case blocked(ownerWorkflowID: String, mode: DesktopWorkflowOwnershipMode)
}

public enum DesktopWorkflowOperationalError: Error, Equatable, LocalizedError, Sendable {
    case bindingUnavailable
    case workflowUnavailable
    case componentUnavailable
    case invalidConfiguration(String)
    case ownershipCollision
    case qualificationRequired
    case migrationBlocked([String])

    public var errorDescription: String? {
        switch self {
        case .bindingUnavailable: "The workflow binding is unavailable."
        case .workflowUnavailable: "The workflow is unavailable."
        case .componentUnavailable: "The workflow component is unavailable."
        case let .invalidConfiguration(detail): "The workflow configuration is invalid: \(detail)"
        case .ownershipCollision: "Another workflow owns or protects this conversation."
        case .qualificationRequired: "The component must pass qualification before it can be enabled."
        case let .migrationBlocked(findings): "Migration cannot advance: \(findings.joined(separator: "; "))"
        }
    }
}

public extension DesktopAppModel {
    var workflowTriggerHealth: [DesktopWorkflowTriggerHealthRecord] {
        snapshot.operations.workflows.triggerHealth
    }

    @discardableResult
    func recordWorkflowTriggerSuccess(
        bindingID: String,
        accountID: String? = nil,
        cursorLagEstimate: Int? = nil
    ) -> Bool {
        guard snapshot.operations.workflows.triggerBindings.contains(where: { $0.id == bindingID }) else { return false }
        let timestamp = now()
        let persisted = persistWorkflowTriggerHealth(DesktopWorkflowTriggerHealthRecord(
            bindingID: bindingID, state: .healthy, lastAttemptAtUnixMillis: timestamp,
            lastSuccessAtUnixMillis: timestamp, nextAttemptAtUnixMillis: nil, consecutiveFailures: 0,
            errorCode: nil, errorSummary: nil, accountID: accountID,
            cursorLagEstimate: cursorLagEstimate.map { max(0, $0) }, authenticationRequired: false
        ))
        if persisted {
            let workflowID = snapshot.operations.workflows.triggerBindings.first { $0.id == bindingID }?.workflowID
            _ = recordWorkflowOperationalStatus(
                workflowID: workflowID, relatedID: bindingID, kind: .triggerLag,
                level: .degraded, summary: "Trigger observation is current.", active: false
            )
            _ = recordWorkflowOperationalStatus(
                workflowID: workflowID, relatedID: bindingID, kind: .authenticationExpired,
                level: .actionRequired, summary: "Provider authentication is current.", active: false
            )
        }
        return persisted
    }

    @discardableResult
    func recordWorkflowTriggerFailure(
        bindingID: String,
        code: String,
        summary: String,
        accountID: String? = nil,
        authenticationRequired: Bool = false
    ) -> Bool {
        guard snapshot.operations.workflows.triggerBindings.contains(where: { $0.id == bindingID }) else { return false }
        let timestamp = now()
        let prior = snapshot.operations.workflows.triggerHealth.first { $0.bindingID == bindingID }
        let failures = min(32, (prior?.consecutiveFailures ?? 0) + 1)
        let exponent = min(10, failures - 1)
        let backoff = min(Int64(3_600_000), Int64(30_000) * Int64(1 << exponent))
        let state: DesktopWorkflowOperationalHealth = authenticationRequired || failures >= 3
            ? .actionRequired : .degraded
        let health = DesktopWorkflowTriggerHealthRecord(
            bindingID: bindingID, state: state, lastAttemptAtUnixMillis: timestamp,
            lastSuccessAtUnixMillis: prior?.lastSuccessAtUnixMillis,
            nextAttemptAtUnixMillis: timestamp + backoff, consecutiveFailures: failures,
            errorCode: String(code.prefix(128)), errorSummary: String(summary.prefix(2_048)),
            accountID: accountID ?? prior?.accountID, cursorLagEstimate: prior?.cursorLagEstimate,
            authenticationRequired: authenticationRequired
        )
        let persisted = persistWorkflowTriggerHealth(
            health,
            actionRequiredDetail: state == .actionRequired
                ? health.errorSummary ?? "Trigger check failed." : nil
        )
        if persisted {
            let workflowID = snapshot.operations.workflows.triggerBindings.first { $0.id == bindingID }?.workflowID
            _ = recordWorkflowOperationalStatus(
                workflowID: workflowID, relatedID: bindingID,
                kind: authenticationRequired ? .authenticationExpired : .triggerLag,
                level: state == .actionRequired ? .actionRequired : .degraded,
                summary: health.errorSummary ?? "Trigger observation is delayed."
            )
        }
        return persisted
    }

    @discardableResult
    func setWorkflowTriggerPaused(bindingID: String, paused: Bool) -> Bool {
        guard let binding = snapshot.operations.workflows.triggerBindings.first(where: { $0.id == bindingID }),
              paused || snapshot.operations.workflows.definitions.contains(where: {
                  $0.id == binding.workflowID && $0.enabled
              }) else { return false }
        let timestamp = now()
        let prior = snapshot.operations.workflows.triggerHealth.first { $0.bindingID == bindingID }
        let health = DesktopWorkflowTriggerHealthRecord(
            bindingID: bindingID, state: paused ? .paused : .unknown,
            lastAttemptAtUnixMillis: prior?.lastAttemptAtUnixMillis,
            lastSuccessAtUnixMillis: prior?.lastSuccessAtUnixMillis,
            nextAttemptAtUnixMillis: nil,
            consecutiveFailures: paused ? prior?.consecutiveFailures ?? 0 : 0,
            errorCode: nil, errorSummary: nil, accountID: prior?.accountID,
            cursorLagEstimate: prior?.cursorLagEstimate, authenticationRequired: false
        )
        return mutate { workspace in
            guard let index = workspace.operations.workflows.triggerBindings.firstIndex(where: { $0.id == bindingID }) else { return }
            workspace.operations.workflows.triggerBindings[index].enabled = !paused
            workspace.operations.workflows.triggerBindings[index].updatedAtUnixMillis = timestamp
            Self.upsert(health, in: &workspace.operations.workflows.triggerHealth)
            workspace.appendAudit(
                domain: "workflow-trigger", action: paused ? "paused" : "resumed",
                target: "binding:\(bindingID)", state: .completed,
                detail: paused ? "Observation is paused; existing work remains visible." : "Observation will resume on the next durable trigger check.",
                recordedAtUnixMillis: timestamp
            )
        }
    }

    @discardableResult
    func upsertWorkflowOwnershipPolicy(
        id: String? = nil,
        workflowID: String,
        accountID: String,
        sourceFilter: String,
        mode: DesktopWorkflowOwnershipMode,
        priority: Int = 0,
        enabled: Bool = true
    ) -> String? {
        guard snapshot.operations.workflows.definitions.contains(where: { $0.id == workflowID }),
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let identifier = id ?? UUID().uuidString.lowercased()
        let timestamp = now()
        let policy = DesktopWorkflowOwnershipPolicyRecord(
            id: identifier, workflowID: workflowID, accountID: String(accountID.prefix(512)),
            sourceFilter: String(sourceFilter.prefix(4_096)), mode: mode,
            priority: min(10_000, max(-10_000, priority)), enabled: enabled,
            createdAtUnixMillis: snapshot.operations.workflows.ownershipPolicies
                .first(where: { $0.id == identifier })?.createdAtUnixMillis ?? timestamp,
            updatedAtUnixMillis: timestamp
        )
        guard mutate({ Self.upsert(policy, in: &$0.operations.workflows.ownershipPolicies) }) else { return nil }
        return identifier
    }

    func claimWorkflowConversation(
        workflowID: String,
        workItemID: String? = nil,
        accountID: String,
        conversationID: String,
        mode: DesktopWorkflowOwnershipMode,
        overrideReason: String? = nil
    ) -> DesktopWorkflowOwnershipDecision {
        let active = snapshot.operations.workflows.ownershipClaims.filter {
            $0.accountID == accountID && $0.conversationID == conversationID && $0.releasedAtUnixMillis == nil
        }
        if let same = active.first(where: { $0.workflowID == workflowID }) { return .acquired(claimID: same.id) }
        let blockers = active.filter { $0.mode != .sharedObservation || mode != .sharedObservation }
        if let blocker = blockers.first, overrideReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .blocked(ownerWorkflowID: blocker.workflowID, mode: blocker.mode)
        }
        let timestamp = now()
        let claim = DesktopWorkflowOwnershipClaimRecord(
            id: UUID().uuidString.lowercased(), workflowID: workflowID, workItemID: workItemID,
            accountID: String(accountID.prefix(512)), conversationID: String(conversationID.prefix(1_024)),
            mode: mode, acquiredAtUnixMillis: timestamp, releasedAtUnixMillis: nil,
            overrideReason: overrideReason.map { String($0.prefix(2_048)) }
        )
        guard mutate({ workspace in
            workspace.operations.workflows.ownershipClaims.append(claim)
            workspace.appendAudit(
                domain: "workflow-ownership", action: blockers.isEmpty ? "claimed" : "overridden",
                target: "conversation:\(claim.conversationID)", state: .completed,
                detail: blockers.isEmpty
                    ? "\(workflowID) acquired \(mode.label.lowercased()) ownership."
                    : "\(workflowID) overrode \(blockers.map(\.workflowID).joined(separator: ", ")): \(claim.overrideReason ?? "No reason")",
                recordedAtUnixMillis: timestamp
            )
        }) else { return .blocked(ownerWorkflowID: "persistence", mode: .protected) }
        if active.isEmpty || mode != .sharedObservation { return .acquired(claimID: claim.id) }
        return .shared(claimID: claim.id, otherWorkflowIDs: Array(Set(active.map(\.workflowID))).sorted())
    }

    @discardableResult
    func releaseWorkflowConversationClaim(id: String, reason: String = "Workflow released the conversation") -> Bool {
        let timestamp = now()
        guard snapshot.operations.workflows.ownershipClaims.contains(where: { $0.id == id && $0.releasedAtUnixMillis == nil }) else { return false }
        return mutateRecord(
            at: \.operations.workflows.ownershipClaims, id: id,
            change: { $0.releasedAtUnixMillis = timestamp },
            audit: DesktopAuditRecord(
                id: UUID().uuidString.lowercased(), domain: "workflow-ownership",
                action: "released", target: "claim:\(id)", state: .completed,
                detail: String(reason.prefix(2_048)), recordedAtUnixMillis: timestamp
            )
        )
    }

    @discardableResult
    func registerWorkflowConnector(_ installation: DesktopWorkflowConnectorInstallationRecord) -> Bool {
        guard Self.validComponentID(installation.connectorID), Self.validVersion(installation.version),
              Self.validDigest(installation.packageDigest), Self.validDigest(installation.executableDigest),
              !installation.effectKinds.isEmpty, installation.effectKinds.count <= 64,
              installation.allowedHosts.count <= 64, installation.secretSlots.count <= 64 else { return false }
        var reviewed = installation
        reviewed.effectKinds = Array(Set(reviewed.effectKinds)).sorted()
        reviewed.allowedHosts = Array(Set(reviewed.allowedHosts.map { $0.lowercased() })).sorted()
        reviewed.secretSlots = Array(Set(reviewed.secretSlots)).sorted()
        reviewed.enabled = reviewed.enabled && reviewed.qualified
        return mutate { Self.upsert(reviewed, in: &$0.operations.workflows.connectorInstallations) }
    }

    @discardableResult
    func registerWorkflowConnector(
        package: DesktopWorkflowConnectorPackageManifest,
        capability: DesktopWorkflowCapabilityInstallationRecord
    ) -> Bool {
        guard package.connectorID == capability.capabilityID,
              package.capabilityID == capability.capabilityID,
              package.version == capability.version else { return false }
        let trust: DesktopWorkflowExtensionTrust = switch capability.trust {
        case .kanameBuiltIn: .kanameBuiltIn
        case .designatedRequirement: .signed
        case .localDigest: .localDigest
        }
        return registerWorkflowConnector(DesktopWorkflowConnectorInstallationRecord(
            connectorID: package.connectorID, name: package.name, version: package.version,
            packageDigest: capability.packageDigest,
            executableDigest: capability.executableDigest ?? capability.packageDigest,
            designatedRequirement: capability.designatedRequirement,
            effectKinds: package.effectKinds, allowedHosts: package.allowedHosts,
            secretSlots: package.secretSlots, trust: trust, enabled: false, qualified: false,
            installedAtUnixMillis: capability.installedAtUnixMillis, lastQualifiedAtUnixMillis: nil
        ))
    }

    @discardableResult
    func bindWorkflowConnector(
        connectorID: String,
        accountID: String?,
        secretReferences: [String: String],
        grantedHosts: [String],
        grantedEffectKinds: [String]
    ) -> String? {
        guard let connector = snapshot.operations.workflows.connectorInstallations
            .filter({ $0.connectorID == connectorID && $0.qualified })
            .sorted(by: { $0.version > $1.version }).first,
              Set(secretReferences.keys).isSubset(of: Set(connector.secretSlots)),
              Set(grantedHosts.map { $0.lowercased() }).isSubset(of: Set(connector.allowedHosts)),
              Set(grantedEffectKinds).isSubset(of: Set(connector.effectKinds)) else { return nil }
        let timestamp = now()
        let binding = DesktopWorkflowConnectorBindingRecord(
            id: UUID().uuidString.lowercased(), connectorID: connectorID, accountID: accountID,
            secretReferences: secretReferences.mapValues { String($0.prefix(512)) },
            grantedHosts: Array(Set(grantedHosts.map { $0.lowercased() })).sorted(),
            grantedEffectKinds: Array(Set(grantedEffectKinds)).sorted(), enabled: true,
            createdAtUnixMillis: timestamp, updatedAtUnixMillis: timestamp
        )
        guard mutate({ $0.operations.workflows.connectorBindings.append(binding) }) else { return nil }
        return binding.id
    }

    @discardableResult
    func recordWorkflowQualification(_ run: DesktopWorkflowQualificationRunRecord) -> Bool {
        guard Self.validComponentID(run.componentID), Self.validVersion(run.componentVersion),
              run.artifactDigests.allSatisfy(Self.validDigest),
              run.outputArtifactDigests.allSatisfy(Self.validDigest),
              run.outputDigest.map(Self.validDigest) ?? true,
              run.assertions.count <= 1_000 else { return false }
        let timestamp = run.executedAtUnixMillis
        return mutate { workspace in
            workspace.operations.workflows.qualificationRuns.append(run)
            if let index = workspace.operations.workflows.connectorInstallations.firstIndex(where: {
                $0.connectorID == run.componentID && $0.version == run.componentVersion
            }) {
                workspace.operations.workflows.connectorInstallations[index].qualified = run.outcome == .passed
                workspace.operations.workflows.connectorInstallations[index].lastQualifiedAtUnixMillis = timestamp
                if run.outcome != .passed { workspace.operations.workflows.connectorInstallations[index].enabled = false }
            }
            if let index = workspace.operations.workflows.rendererInstallations.firstIndex(where: {
                $0.rendererID == run.componentID && $0.version == run.componentVersion
            }) {
                workspace.operations.workflows.rendererInstallations[index].qualified = run.outcome == .passed
                if run.outcome != .passed { workspace.operations.workflows.rendererInstallations[index].enabled = false }
            }
        }
    }

    @discardableResult
    func registerWorkflowRenderer(_ installation: DesktopWorkflowRendererInstallationRecord) -> Bool {
        guard Self.validComponentID(installation.rendererID), Self.validVersion(installation.version),
              Self.validDigest(installation.packageDigest), !installation.mediaTypes.isEmpty else { return false }
        var reviewed = installation
        reviewed.mediaTypes = Array(Set(reviewed.mediaTypes)).sorted()
        reviewed.enabled = reviewed.enabled && reviewed.qualified
        return mutate { Self.upsert(reviewed, in: &$0.operations.workflows.rendererInstallations) }
    }

    @discardableResult
    func registerWorkflowRenderer(
        package: DesktopWorkflowRendererManifest,
        capability: DesktopWorkflowCapabilityInstallationRecord
    ) -> Bool {
        guard package.rendererID == capability.capabilityID,
              package.capabilityID == capability.capabilityID,
              package.version == capability.version else { return false }
        return registerWorkflowRenderer(DesktopWorkflowRendererInstallationRecord(
            rendererID: package.rendererID, name: package.name, version: package.version,
            packageDigest: capability.packageDigest, mediaTypes: package.mediaTypes,
            supportsRecalculation: package.supportsRecalculation,
            supportsRangeSelection: package.supportsRangeSelection,
            enabled: false, qualified: false, installedAtUnixMillis: capability.installedAtUnixMillis
        ))
    }

    @discardableResult
    func setWorkflowConnectorEnabled(id: String, enabled: Bool) -> Bool {
        guard let installation = snapshot.operations.workflows.connectorInstallations.first(where: { $0.id == id }),
              !enabled || installation.qualified,
              !enabled || snapshot.operations.workflows.connectorBindings.contains(where: {
                  $0.connectorID == installation.connectorID && $0.enabled
              }) else { return false }
        return mutateRecord(at: \.operations.workflows.connectorInstallations, id: id) { $0.enabled = enabled }
    }

    @discardableResult
    func setWorkflowRendererEnabled(id: String, enabled: Bool) -> Bool {
        guard let installation = snapshot.operations.workflows.rendererInstallations.first(where: { $0.id == id }),
              !enabled || installation.qualified else { return false }
        return mutateRecord(at: \.operations.workflows.rendererInstallations, id: id) { $0.enabled = enabled }
    }

    @discardableResult
    func recordWorkflowRenderReceipt(_ receipt: DesktopWorkflowRenderReceiptRecord) -> Bool {
        guard snapshot.operations.workflows.rendererInstallations.contains(where: {
            $0.rendererID == receipt.rendererID && $0.enabled && $0.qualified
        }), Self.validDigest(receipt.sourceArtifactDigest),
              receipt.previewArtifactDigests.allSatisfy(Self.validDigest) else { return false }
        return mutate { $0.operations.workflows.renderReceipts.append(receipt) }
    }

    @discardableResult
    func installWorkflowSubflow(_ subflow: DesktopWorkflowSubflowRecord) -> Bool {
        guard Self.validComponentID(subflow.subflowID), Self.validVersion(subflow.version),
              Self.validDigest(subflow.manifestDigest),
              DesktopWorkflowJSONSchemaValidator.validateSchema(Data(subflow.inputSchema.utf8)),
              DesktopWorkflowJSONSchemaValidator.validateSchema(Data(subflow.outputSchema.utf8)),
              (try? DesktopWorkflowHostContractValidation.validateGraph(subflow.steps)) != nil else { return false }
        return mutate { Self.upsert(subflow, in: &$0.operations.workflows.subflows) }
    }

    @discardableResult
    func installWorkflowSubflow(
        manifest: DesktopWorkflowPackageManifest,
        inputSchema: String,
        outputSchema: String
    ) -> Bool {
        guard (try? DesktopWorkflowPackageCodec.validate(
            manifest,
            registeredCapabilityIDs: Set(snapshot.operations.workflows.capabilityInstallations.map(\.capabilityID))
        )) != nil,
              let canonical = try? DesktopWorkflowPackageCodec.canonicalData(manifest) else { return false }
        return installWorkflowSubflow(DesktopWorkflowSubflowRecord(
            subflowID: manifest.id, name: manifest.name, summary: manifest.summary,
            version: manifest.version, manifestDigest: DesktopWorkflowPackageCodec.digest(canonical),
            inputSchema: inputSchema, outputSchema: outputSchema,
            permissions: manifest.permissions, steps: manifest.steps, enabled: true,
            installedAtUnixMillis: now()
        ))
    }

    @discardableResult
    func createWorkflowStudioDraft(
        name: String,
        summary: String,
        icon: String = "point.3.connected.trianglepath.dotted",
        version: String = "1.0.0"
    ) -> String? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, Self.validVersion(version) else { return nil }
        let timestamp = now()
        let id = UUID().uuidString.lowercased()
        let draft = DesktopWorkflowStudioDraftRecord(
            id: id, workflowID: "local.\(id)", name: String(cleanName.prefix(256)),
            summary: String(summary.prefix(2_048)), icon: String(icon.prefix(128)), version: version,
            triggerKinds: [.manual], steps: [], permissions: .init(), subflows: [],
            validationSummary: "Add at least one step and a terminal Complete step.",
            createdAtUnixMillis: timestamp, updatedAtUnixMillis: timestamp
        )
        var prepared = draft
        prepared.manifestMetadata = .newDraft
        guard mutate({ $0.operations.workflows.studioDrafts.append(prepared) }) else { return nil }
        return id
    }

    @discardableResult
    func updateWorkflowStudioDraft(
        id: String,
        triggerKinds: [DesktopWorkflowTriggerKind],
        steps: [DesktopWorkflowStepDefinition],
        permissions: DesktopWorkflowPermissionEnvelope,
        subflows: [DesktopWorkflowSubflowReference],
        canvasPositions: [DesktopWorkflowCanvasNodePosition]? = nil,
        manifestMetadata: DesktopWorkflowStudioManifestMetadata? = nil,
        recordUndo: Bool = true
    ) -> Bool {
        guard !triggerKinds.isEmpty, Set(steps.map(\.id)).count == steps.count,
              Set(subflows.map { "\($0.subflowID)@\($0.version)" }).count == subflows.count,
              subflows.allSatisfy({ reference in
                  snapshot.operations.workflows.subflows.contains {
                      $0.subflowID == reference.subflowID && $0.version == reference.version && $0.enabled
                  }
              }) else { return false }
        let metadata = manifestMetadata
            ?? snapshot.operations.workflows.studioDrafts.first(where: { $0.id == id })?.manifestMetadata
            ?? .newDraft
        let diagnostics = DesktopWorkflowStudioValidation.diagnostics(steps: steps, metadata: metadata)
        let validation: String?
        do {
            try DesktopWorkflowHostContractValidation.validateGraph(steps)
            for step in steps { try DesktopWorkflowHostContractValidation.validate(step: step, stepIDs: Set(steps.map(\.id))) }
            let broadened = subflows.compactMap { reference in
                snapshot.operations.workflows.subflows.first {
                    $0.subflowID == reference.subflowID && $0.version == reference.version
                }
            }.first { $0.permissions.broadens(permissions) }
            validation = diagnostics.first(where: { $0.severity == .error })?.message
                ?? (broadened == nil ? nil : "Subflow \(broadened!.name) requires authority outside the draft envelope.")
        } catch {
            validation = error.localizedDescription
        }
        let timestamp = now()
        return mutateRecord(at: \.operations.workflows.studioDrafts, id: id) { draft in
            if recordUndo {
                var undo = draft.undoHistory ?? []
                undo.append(Self.studioSnapshot(draft))
                draft.undoHistory = Array(undo.suffix(50))
                draft.redoHistory = []
            }
            draft.triggerKinds = Array(Set(triggerKinds)).sorted { $0.rawValue < $1.rawValue }
            draft.steps = steps
            draft.permissions = permissions
            draft.subflows = subflows
            draft.canvasPositions = canvasPositions ?? draft.canvasPositions
            draft.manifestMetadata = metadata
            draft.validationSummary = validation
            draft.updatedAtUnixMillis = timestamp
        }
    }

    @discardableResult
    func forkWorkflowRevisionToStudio(revisionID: String) -> String? {
        guard let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == revisionID }),
              let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == revision.workflowID }) else { return nil }
        return createWorkflowStudioDraft(
            definition: definition,
            revision: revision,
            workflowIdentity: { "local.\($0)" },
            name: definition.name + " copy",
            version: revision.version
        )
    }

    @discardableResult
    func editWorkflowRevisionInStudio(revisionID: String) -> String? {
        guard let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == revisionID }),
              let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == revision.workflowID }),
              let nextVersion = Self.nextWorkflowVersion(revision.version) else { return nil }
        return createWorkflowStudioDraft(
            definition: definition,
            revision: revision,
            workflowIdentity: { _ in definition.id },
            name: definition.name,
            version: nextVersion
        )
    }

    private func createWorkflowStudioDraft(
        definition: DesktopWorkflowDefinitionRecord,
        revision: DesktopWorkflowRevisionRecord,
        workflowIdentity: (String) -> String,
        name: String,
        version: String
    ) -> String? {
        let timestamp = now()
        let id = UUID().uuidString.lowercased()
        var draft = DesktopWorkflowStudioDraftRecord(
            id: id, workflowID: workflowIdentity(id), name: name,
            summary: definition.summary, icon: definition.icon, version: version,
            triggerKinds: definition.triggerKinds, steps: revision.steps, permissions: revision.permissions,
            subflows: [], validationSummary: nil, createdAtUnixMillis: timestamp, updatedAtUnixMillis: timestamp
        )
        draft.canvasPositions = Self.defaultCanvasPositions(revision.steps)
        draft.manifestMetadata = Self.studioMetadata(definition: definition, revision: revision)
        let diagnostics = DesktopWorkflowStudioValidation.diagnostics(
            steps: revision.steps, metadata: draft.manifestMetadata ?? .newDraft
        )
        draft.validationSummary = diagnostics.first(where: { $0.severity == .error })?.message
        guard mutate({ $0.operations.workflows.studioDrafts.append(draft) }) else { return nil }
        return id
    }

    func workflowStudioManifest(draftID: String) -> DesktopWorkflowPackageManifest? {
        guard let draft = snapshot.operations.workflows.studioDrafts.first(where: { $0.id == draftID }) else { return nil }
        return Self.studioManifest(draft)
    }

    func workflowStudioCanonicalSource(draftID: String) -> String? {
        guard let manifest = workflowStudioManifest(draftID: draftID),
              let data = try? DesktopWorkflowPackageCodec.canonicalData(manifest) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func workflowStudioDiagnostics(draftID: String) -> [DesktopWorkflowStudioDiagnostic] {
        guard let draft = snapshot.operations.workflows.studioDrafts.first(where: { $0.id == draftID }) else { return [] }
        return DesktopWorkflowStudioValidation.diagnostics(
            steps: draft.steps, metadata: draft.manifestMetadata ?? .newDraft
        )
    }

    @discardableResult
    func replaceWorkflowStudioDraftSource(id: String, source: String) -> Bool {
        guard let data = source.data(using: .utf8), data.count <= DesktopWorkflowPackageCodec.maximumManifestBytes,
              let manifest = try? DesktopWorkflowPackageCodec.decode(
                  data,
                  registeredCapabilityIDs: Set(snapshot.operations.workflows.capabilityInstallations.map(\.capabilityID))
              ),
              let draft = snapshot.operations.workflows.studioDrafts.first(where: { $0.id == id }) else { return false }
        return mutateRecord(at: \.operations.workflows.studioDrafts, id: id) { stored in
            var undo = stored.undoHistory ?? []
            undo.append(Self.studioSnapshot(draft))
            stored.undoHistory = Array(undo.suffix(50))
            stored.redoHistory = []
            stored.workflowID = manifest.id
            stored.name = manifest.name
            stored.summary = manifest.summary
            stored.icon = manifest.icon
            stored.version = manifest.version
            stored.triggerKinds = manifest.triggers
            stored.steps = manifest.steps
            stored.permissions = manifest.permissions
            stored.subflows = []
            stored.canvasPositions = Self.defaultCanvasPositions(manifest.steps)
            stored.manifestMetadata = Self.studioMetadata(manifest)
            stored.validationSummary = nil
            stored.updatedAtUnixMillis = now()
        }
    }

    @discardableResult
    func undoWorkflowStudioDraft(id: String) -> Bool { moveStudioHistory(id: id, undo: true) }

    @discardableResult
    func redoWorkflowStudioDraft(id: String) -> Bool { moveStudioHistory(id: id, undo: false) }

    private func moveStudioHistory(id: String, undo: Bool) -> Bool {
        mutateRecord(at: \.operations.workflows.studioDrafts, id: id) { draft in
            var source = undo ? (draft.undoHistory ?? []) : (draft.redoHistory ?? [])
            guard let selected = source.popLast() else { return }
            var destination = undo ? (draft.redoHistory ?? []) : (draft.undoHistory ?? [])
            destination.append(Self.studioSnapshot(draft))
            if undo { draft.undoHistory = source; draft.redoHistory = Array(destination.suffix(50)) }
            else { draft.redoHistory = source; draft.undoHistory = Array(destination.suffix(50)) }
            Self.restoreStudioSnapshot(selected, into: &draft)
            draft.updatedAtUnixMillis = now()
        }
    }

    @discardableResult
    func publishWorkflowStudioDraft(id: String) -> String? {
        guard let draft = snapshot.operations.workflows.studioDrafts.first(where: { $0.id == id }),
              draft.validationSummary == nil else { return nil }
        guard let steps = flattenedStudioSteps(draft) else { return nil }
        var publishDraft = draft
        publishDraft.steps = steps
        let manifest = Self.studioManifest(publishDraft)
        guard let data = try? DesktopWorkflowPackageCodec.canonicalData(manifest),
              (try? installWorkflowPackage(
                  manifestData: data,
                  registeredCapabilityIDs: Set(snapshot.operations.workflows.capabilityInstallations.map(\.capabilityID)),
                  enable: false
              )) != nil else { return nil }
        return draft.workflowID
    }

    private static func studioManifest(_ draft: DesktopWorkflowStudioDraftRecord) -> DesktopWorkflowPackageManifest {
        let metadata = draft.manifestMetadata ?? .newDraft
        return DesktopWorkflowPackageManifest(
            schemaVersion: metadata.schemaVersion, id: draft.workflowID, name: draft.name, summary: draft.summary,
            icon: draft.icon, version: draft.version, source: metadata.source, license: metadata.license,
            triggers: draft.triggerKinds, steps: draft.steps, permissions: draft.permissions,
            correlationSummary: metadata.correlationSummary, contextSummary: metadata.contextSummary,
            completionSummary: metadata.completionSummary, datasets: metadata.datasets,
            configurationSchema: metadata.configurationSchema,
            configurationSchemaVersion: metadata.configurationSchemaVersion,
            manualRunInputSchema: metadata.manualRunInputSchema, bindingSlots: metadata.bindingSlots,
            providerFeatures: metadata.providerFeatures, hostCompatibility: metadata.hostCompatibility,
            dependencies: metadata.dependencies, publisher: metadata.publisher, provenance: metadata.provenance,
            uiHints: metadata.uiHints, configurationMigrations: metadata.configurationMigrations
        )
    }

    private static func studioMetadata(_ manifest: DesktopWorkflowPackageManifest) -> DesktopWorkflowStudioManifestMetadata {
        .init(
            schemaVersion: manifest.schemaVersion, source: manifest.source, license: manifest.license,
            correlationSummary: manifest.correlationSummary, contextSummary: manifest.contextSummary,
            completionSummary: manifest.completionSummary, datasets: manifest.datasets,
            configurationSchema: manifest.configurationSchema,
            configurationSchemaVersion: manifest.configurationSchemaVersion,
            manualRunInputSchema: manifest.manualRunInputSchema, bindingSlots: manifest.bindingSlots,
            providerFeatures: manifest.providerFeatures, hostCompatibility: manifest.hostCompatibility,
            dependencies: manifest.dependencies, publisher: manifest.publisher, provenance: manifest.provenance,
            uiHints: manifest.uiHints, configurationMigrations: manifest.configurationMigrations
        )
    }

    private static func studioMetadata(
        definition: DesktopWorkflowDefinitionRecord,
        revision: DesktopWorkflowRevisionRecord
    ) -> DesktopWorkflowStudioManifestMetadata {
        .init(
            schemaVersion: revision.schemaVersion, source: definition.source, license: definition.license,
            correlationSummary: revision.correlationSummary, contextSummary: revision.contextSummary,
            completionSummary: revision.completionSummary, datasets: revision.datasetDefinitions,
            configurationSchema: revision.configurationSchema,
            configurationSchemaVersion: revision.configurationSchemaVersion,
            manualRunInputSchema: revision.manualRunInputSchema, bindingSlots: revision.bindingSlots,
            providerFeatures: revision.providerFeatures, hostCompatibility: revision.hostCompatibility,
            dependencies: revision.dependencies, publisher: revision.publisher, provenance: revision.provenance,
            uiHints: revision.uiHints, configurationMigrations: revision.configurationMigrations
        )
    }

    private static func studioSnapshot(_ draft: DesktopWorkflowStudioDraftRecord) -> DesktopWorkflowStudioSnapshot {
        .init(
            steps: draft.steps, triggerKinds: draft.triggerKinds, permissions: draft.permissions,
            subflows: draft.subflows, canvasPositions: draft.canvasPositions ?? [],
            metadata: draft.manifestMetadata ?? .newDraft
        )
    }

    private static func restoreStudioSnapshot(
        _ snapshot: DesktopWorkflowStudioSnapshot,
        into draft: inout DesktopWorkflowStudioDraftRecord
    ) {
        draft.steps = snapshot.steps
        draft.triggerKinds = snapshot.triggerKinds
        draft.permissions = snapshot.permissions
        draft.subflows = snapshot.subflows
        draft.canvasPositions = snapshot.canvasPositions
        draft.manifestMetadata = snapshot.metadata
        draft.validationSummary = DesktopWorkflowStudioValidation.diagnostics(
            steps: snapshot.steps, metadata: snapshot.metadata
        ).first(where: { $0.severity == .error })?.message
    }

    private static func defaultCanvasPositions(_ steps: [DesktopWorkflowStepDefinition]) -> [DesktopWorkflowCanvasNodePosition] {
        steps.enumerated().map { index, step in
            .init(stepID: step.id, x: Double(index % 4) * 230 + 30, y: Double(index / 4) * 130 + 30)
        }
    }

    private func flattenedStudioSteps(_ draft: DesktopWorkflowStudioDraftRecord) -> [DesktopWorkflowStepDefinition]? {
        var groups: [(prefix: String, steps: [DesktopWorkflowStepDefinition])] = []
        for (index, reference) in draft.subflows.enumerated() {
            guard let subflow = snapshot.operations.workflows.subflows.first(where: {
                $0.subflowID == reference.subflowID && $0.version == reference.version && $0.enabled
            }), DesktopWorkflowPermissionMonotonicity.permits(
                callee: subflow.permissions, within: draft.permissions
            ) else { return nil }
            groups.append(("subflow\(index)-", subflow.steps))
        }
        if !draft.steps.isEmpty { groups.append(("", draft.steps)) }
        guard !groups.isEmpty else { return nil }
        var flattened: [DesktopWorkflowStepDefinition] = []
        for groupIndex in groups.indices {
            let group = groups[groupIndex]
            let nextEntry: String? = groups.indices.contains(groupIndex + 1)
                ? groups[groupIndex + 1].prefix + (groups[groupIndex + 1].steps.first?.id ?? "")
                : nil
            let terminalIDs = Set(group.steps.filter { $0.kind == .complete }.map(\.id))
            for var step in group.steps {
                if step.kind == .complete, nextEntry != nil { continue }
                step = DesktopWorkflowStepDefinition(
                    id: group.prefix + step.id, name: step.name, kind: step.kind,
                    capabilityID: step.capabilityID, inputSchemaReference: step.inputSchemaReference,
                    outputSchemaReference: step.outputSchemaReference, retryLimit: step.retryLimit,
                    isIdempotent: step.isIdempotent, blocking: step.blocking,
                    artifactInputs: step.artifactInputs, stateInputs: step.stateInputs,
                    transitions: step.transitions?.map { transition in
                        DesktopWorkflowTransitionDefinition(
                            outcome: transition.outcome,
                            targetStepID: terminalIDs.contains(transition.targetStepID) && nextEntry != nil
                                ? nextEntry! : group.prefix + transition.targetStepID,
                            predicates: transition.predicates
                        )
                    }, reviewContract: step.reviewContract, waitContract: step.waitContract,
                    executionPolicy: step.executionPolicy, agentPolicy: step.agentPolicy,
                    inputMappings: step.inputMappings, batchPolicy: step.batchPolicy
                )
                flattened.append(step)
            }
        }
        return flattened
    }

    @discardableResult
    func upsertWorkflowSchedule(
        id: String? = nil,
        workflowID: String,
        spec: DesktopScheduleSpec,
        timeZoneIdentifier: String,
        missedRunPolicy: DesktopAutomationRule.MissedRunPolicy,
        enabled: Bool
    ) -> String? {
        guard snapshot.operations.workflows.definitions.contains(where: { $0.id == workflowID }),
              TimeZone(identifier: timeZoneIdentifier) != nil else { return nil }
        let timestamp = now()
        guard let next = try? DesktopScheduleEngine.nextOccurrence(
            spec: spec, timeZoneIdentifier: timeZoneIdentifier, after: timestamp - 1
        ) else { return nil }
        let identifier = id ?? UUID().uuidString.lowercased()
        let record = DesktopWorkflowScheduleBindingRecord(
            id: identifier, workflowID: workflowID, spec: spec, timeZoneIdentifier: timeZoneIdentifier,
            missedRunPolicy: missedRunPolicy, enabled: enabled, nextRunAtUnixMillis: enabled ? next : nil,
            lastScheduledAtUnixMillis: nil,
            createdAtUnixMillis: snapshot.operations.workflows.scheduleBindings
                .first(where: { $0.id == identifier })?.createdAtUnixMillis ?? timestamp,
            updatedAtUnixMillis: timestamp
        )
        guard mutate({ Self.upsert(record, in: &$0.operations.workflows.scheduleBindings) }) else { return nil }
        return identifier
    }

    func claimDueWorkflowSchedules(at timestamp: Int64? = nil) -> [DesktopWorkflowScheduleBindingRecord] {
        let checkedAt = timestamp ?? now()
        let due = snapshot.operations.workflows.scheduleBindings.filter {
            $0.enabled && ($0.nextRunAtUnixMillis ?? Int64.max) <= checkedAt
        }.sorted { ($0.nextRunAtUnixMillis ?? 0) < ($1.nextRunAtUnixMillis ?? 0) }
        guard !due.isEmpty else { return [] }
        _ = mutate { workspace in
            for schedule in due {
                guard let index = workspace.operations.workflows.scheduleBindings.firstIndex(where: { $0.id == schedule.id }) else { continue }
                let scheduledAt = schedule.nextRunAtUnixMillis
                workspace.operations.workflows.scheduleBindings[index].lastScheduledAtUnixMillis = scheduledAt
                workspace.operations.workflows.scheduleBindings[index].nextRunAtUnixMillis = try? DesktopScheduleEngine.nextOccurrence(
                    spec: schedule.spec, timeZoneIdentifier: schedule.timeZoneIdentifier, after: max(checkedAt, scheduledAt ?? checkedAt)
                )
                workspace.operations.workflows.scheduleBindings[index].updatedAtUnixMillis = checkedAt
            }
        }
        return due
    }

    @discardableResult
    func createWorkflowMigrationAssessment(
        workflowID: String,
        requiredScenarioIDs: [String],
        installationID: String? = nil
    ) -> String? {
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == workflowID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == definition.currentRevisionID }),
              !requiredScenarioIDs.isEmpty else { return nil }
        let candidates = snapshot.operations.workflows.installations.filter {
            $0.workflowID == workflowID && $0.workflowRevisionID == revision.id
        }
        let installation = installationID.flatMap { selectedID in
            candidates.first(where: { $0.id == selectedID })
        } ?? (candidates.count == 1 ? candidates[0] : nil)
        if installationID != nil, installation == nil { return nil }
        let lock = installation.flatMap { selected in
            snapshot.operations.workflows.dependencyLockRevisions.first {
                $0.id == selected.currentDependencyLockRevisionID && $0.installationID == selected.id
            }
        }
        let timestamp = now()
        let assessment = DesktopWorkflowMigrationAssessmentRecord(
            id: UUID().uuidString.lowercased(), workflowID: workflowID, stage: .observeOnly,
            requiredScenarioIDs: Array(Set(requiredScenarioIDs)).sorted(), passedScenarioIDs: [],
            blockingFindings: [], legacyOutputDigest: nil, kanameOutputDigest: nil,
            workflowRevisionID: revision.id, manifestDigest: revision.manifestDigest,
            installationID: installation?.id, dependencyLockRevisionID: lock?.id,
            dependencyLockDigest: lock?.digest,
            createdAtUnixMillis: timestamp, updatedAtUnixMillis: timestamp
        )
        guard mutate({ $0.operations.workflows.migrationAssessments.append(assessment) }) else { return nil }
        return assessment.id
    }

    @discardableResult
    func updateWorkflowMigrationEvidence(
        id: String,
        passedScenarioIDs: [String],
        blockingFindings: [String],
        legacyOutputDigest: String? = nil,
        kanameOutputDigest: String? = nil
    ) -> Bool {
        guard legacyOutputDigest.map(Self.validDigest) ?? true,
              kanameOutputDigest.map(Self.validDigest) ?? true else { return false }
        let timestamp = now()
        return mutateRecord(at: \.operations.workflows.migrationAssessments, id: id) { assessment in
            assessment.passedScenarioIDs = Array(Set(passedScenarioIDs)).sorted()
            assessment.blockingFindings = blockingFindings.prefix(128).map { String($0.prefix(2_048)) }
            assessment.legacyOutputDigest = legacyOutputDigest
            assessment.kanameOutputDigest = kanameOutputDigest
            assessment.updatedAtUnixMillis = timestamp
        }
    }

    func advanceWorkflowMigration(id: String, to stage: DesktopWorkflowMigrationStage) throws {
        guard let assessment = snapshot.operations.workflows.migrationAssessments.first(where: { $0.id == id }) else {
            throw DesktopWorkflowOperationalError.componentUnavailable
        }
        let order = DesktopWorkflowMigrationStage.allCases
        guard let currentIndex = order.firstIndex(of: assessment.stage), let targetIndex = order.firstIndex(of: stage),
              targetIndex == currentIndex + 1 else {
            throw DesktopWorkflowOperationalError.invalidConfiguration("migration stages advance one reviewed step at a time")
        }
        let missing = Set(assessment.requiredScenarioIDs).subtracting(assessment.passedScenarioIDs).sorted()
        var blockers = assessment.blockingFindings
        if !missing.isEmpty { blockers.append("Missing scenarios: \(missing.joined(separator: ", "))") }
        blockers.append(contentsOf: workflowMigrationEvidenceBlockers(assessment))
        if stage == .legacyRetired, assessment.legacyOutputDigest != assessment.kanameOutputDigest {
            blockers.append("Legacy and Kaname fixture outputs do not match.")
        }
        guard blockers.isEmpty else { throw DesktopWorkflowOperationalError.migrationBlocked(blockers) }
        let timestamp = now()
        guard mutate({ workspace in
            guard let index = workspace.operations.workflows.migrationAssessments.firstIndex(where: { $0.id == id }) else { return }
            workspace.operations.workflows.migrationAssessments[index].stage = stage
            workspace.operations.workflows.migrationAssessments[index].updatedAtUnixMillis = timestamp
            workspace.appendAudit(
                domain: "workflow-migration", action: "advanced", target: "assessment:\(id)",
                state: .completed, detail: "Advanced to \(stage.label).", recordedAtUnixMillis: timestamp
            )
        }) else { throw DesktopWorkflowOperationalError.componentUnavailable }
    }

    private func workflowMigrationEvidenceBlockers(
        _ assessment: DesktopWorkflowMigrationAssessmentRecord
    ) -> [String] {
        guard let revisionID = assessment.workflowRevisionID,
              let manifestDigest = assessment.manifestDigest,
              let fixtureSuiteID = assessment.fixtureSuiteID,
              let fixtureSuiteDigest = assessment.fixtureSuiteDigest else {
            return ["Automated revision-bound comparison evidence is missing."]
        }
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == assessment.workflowID }),
              definition.currentRevisionID == revisionID,
              let revision = snapshot.operations.workflows.revisions.first(where: {
                  $0.id == revisionID && $0.manifestDigest == manifestDigest
              }) else {
            return ["The workflow package revision changed after evidence was recorded."]
        }
        if revision.schemaVersion >= 3 {
            guard let installationID = assessment.installationID,
                  let lockID = assessment.dependencyLockRevisionID,
                  let lockDigest = assessment.dependencyLockDigest,
                  let installation = snapshot.operations.workflows.installations.first(where: {
                      $0.id == installationID && $0.workflowRevisionID == revisionID
                  }),
                  installation.readinessIssues.isEmpty,
                  installation.currentDependencyLockRevisionID == lockID,
                  snapshot.operations.workflows.dependencyLockRevisions.contains(where: {
                      $0.id == lockID && $0.installationID == installationID && $0.digest == lockDigest
                  }) else {
                return ["The installation or dependency lock changed after evidence was recorded."]
            }
        }
        let evidenceIDs = Set(assessment.comparisonEvidenceIDs ?? [])
        var findings: [String] = []
        for scenarioID in assessment.requiredScenarioIDs {
            let candidates = snapshot.operations.workflows.migrationComparisons.filter {
                evidenceIDs.contains($0.id) && $0.assessmentID == assessment.id && $0.scenarioID == scenarioID
            }.sorted { ($0.createdAtUnixMillis, $0.id) > ($1.createdAtUnixMillis, $1.id) }
            guard let comparison = candidates.first else {
                findings.append("Scenario \(scenarioID) has no automated comparison evidence.")
                continue
            }
            guard comparison.workflowRevisionID == revisionID,
                  comparison.manifestDigest == manifestDigest,
                  comparison.installationID == assessment.installationID,
                  comparison.dependencyLockRevisionID == assessment.dependencyLockRevisionID,
                  comparison.dependencyLockDigest == assessment.dependencyLockDigest,
                  comparison.fixtureSuiteID == fixtureSuiteID,
                  comparison.fixtureSuiteDigest == fixtureSuiteDigest else {
                findings.append("Scenario \(scenarioID) evidence is stale or version-mismatched.")
                continue
            }
            guard comparison.evidenceDigest == DesktopWorkflowSimulationEngine.comparisonEvidenceDigest(comparison) else {
                findings.append("Scenario \(scenarioID) evidence was edited after generation.")
                continue
            }
            guard let run = snapshot.operations.workflows.simulationRuns.first(where: {
                $0.id == comparison.simulationRunID && $0.workflowRevisionID == revisionID
                    && $0.manifestDigest == manifestDigest && $0.fixtureSuiteID == fixtureSuiteID
                    && $0.fixtureSuiteDigest == fixtureSuiteDigest && $0.scenarioID == scenarioID
                    && $0.outputDigest == comparison.kanameOutputDigest && $0.outcome == .passed
            }), DesktopWorkflowSimulationEngine.replay(run) else {
                findings.append("Scenario \(scenarioID) simulation evidence is incomplete or edited.")
                continue
            }
            if !comparison.matched {
                findings.append("Scenario \(scenarioID) legacy and Kaname outputs differ.")
            }
        }
        return findings
    }

    private static func upsert<Record: Identifiable>(_ record: Record, in records: inout [Record]) where Record.ID: Equatable {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
    }

    private func persistWorkflowTriggerHealth(
        _ health: DesktopWorkflowTriggerHealthRecord,
        actionRequiredDetail: String? = nil
    ) -> Bool {
        mutate { workspace in
            Self.upsert(health, in: &workspace.operations.workflows.triggerHealth)
            if let actionRequiredDetail {
                workspace.appendAudit(
                    domain: "workflow-trigger", action: "action-required",
                    target: "binding:\(health.bindingID)", state: .failed,
                    detail: actionRequiredDetail, recordedAtUnixMillis: health.lastAttemptAtUnixMillis ?? now()
                )
            }
        }
    }

    private static func validComponentID(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }

    private static func validVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil
    }

    private static func nextWorkflowVersion(_ value: String) -> String? {
        guard validVersion(value) else { return nil }
        var components = value.split(separator: ".").compactMap { Int($0) }
        guard !components.isEmpty, let last = components.last, last < Int.max else { return nil }
        components[components.count - 1] = last + 1
        return components.map(String.init).joined(separator: ".")
    }

    private static func validDigest(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }
}
