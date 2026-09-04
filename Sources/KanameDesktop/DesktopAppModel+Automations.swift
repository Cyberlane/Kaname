import Combine
import CryptoKit
import Foundation
import KanameConnectivity
import KanameDomain
import KanameLocalCore
#if os(macOS)
import Darwin
#endif

extension DesktopAppModel {
    @discardableResult
    public func createAutomation(
        name: String,
        schedule: String,
        timeZoneIdentifier: String,
        actionSummary: String,
        missedRunPolicy: DesktopAutomationRule.MissedRunPolicy,
        scheduleSpec: DesktopScheduleSpec? = nil,
        actionKind: DesktopAutomationActionKind? = nil,
        authority: DesktopAutomationAuthority? = nil,
        projectID: String? = nil,
        skillIDs: [String] = [],
        toolNames: [String] = [],
        notificationEnabled: Bool = true
    ) -> String? {
        let fields = [name, schedule, actionSummary].map(Self.normalized)
        guard fields.allSatisfy({ !$0.isEmpty }),
              TimeZone(identifier: timeZoneIdentifier) != nil else { return nil }
        var rule = DesktopAutomationRule(
            id: UUID().uuidString.lowercased(),
            name: fields[0],
            schedule: fields[1],
            timeZoneIdentifier: timeZoneIdentifier,
            actionSummary: fields[2],
            missedRunPolicy: missedRunPolicy,
            status: .draft,
            nextRunAtUnixMillis: nil,
            lastResult: "Not run",
            createdAtUnixMillis: now()
        )
        rule.scheduleSpec = scheduleSpec
        rule.actionKind = actionKind
        rule.authority = authority
        rule.projectID = projectID
        rule.skillIDs = Array(Set(skillIDs)).sorted()
        rule.toolNames = Array(Set(toolNames.map(Self.normalized).filter { !$0.isEmpty })).sorted()
        rule.notificationEnabled = notificationEnabled
        mutate { $0.domains.automations.append(rule) }
        return rule.id
    }

    public func activateAutomation(id: String, approvalID: String?) -> Bool {
        guard let rule = snapshot.domains.automations.first(where: { $0.id == id }),
              let spec = rule.scheduleSpec,
              rule.actionKind != nil,
              rule.authority != nil,
              !(rule.actionKind != .notification && rule.authority == .localOnly),
              (rule.toolNames ?? []).isEmpty,
              (rule.actionKind != .skill || !(rule.skillIDs ?? []).isEmpty),
              (rule.skillIDs ?? []).allSatisfy({ skillID in
                  snapshot.domains.skills.contains { $0.id == skillID && $0.enabled }
              }) else { return false }
        if rule.authority != .localOnly {
            guard let approvalID, let target = automationAuthorityTarget(for: rule),
                  isApprovalGranted(id: approvalID, exactTarget: target) else { return false }
        }
        let timestamp = now()
        guard let next = try? DesktopScheduleEngine.nextOccurrence(
            spec: spec,
            timeZoneIdentifier: rule.timeZoneIdentifier,
            after: timestamp - 1
        ) else { return false }
        mutateRecord(at: \.domains.automations, id: id) { automation in
            automation.status = .ready
            automation.nextRunAtUnixMillis = next
            automation.lastResult = "Scheduled"
            if automation.authority == .standing {
                automation.standingAuthorityApprovedAtUnixMillis = timestamp
                automation.standingAuthorityApprovalID = approvalID
            }
        }
        return true
    }

    public func automationAuthorityTarget(for rule: DesktopAutomationRule) -> String? {
        struct Capability: Encodable {
            let id: String
            let name: String
            let kind: String
            let revision: String
            let source: String
            let scope: String
        }
        struct Contract: Encodable {
            let id: String
            let name: String
            let schedule: DesktopScheduleSpec
            let timeZoneIdentifier: String
            let actionSummary: String
            let missedRunPolicy: String
            let actionKind: String
            let authority: String
            let projectID: String?
            let workspacePath: String?
            let capabilities: [Capability]
            let notificationEnabled: Bool
        }
        guard let schedule = rule.scheduleSpec,
              let actionKind = rule.actionKind,
              let authority = rule.authority else { return nil }
        var selected: [Capability] = []
        for id in rule.skillIDs ?? [] {
            guard let skill = snapshot.domains.skills.first(where: { $0.id == id }) else { continue }
            selected.append(Capability(
                id: skill.id,
                name: skill.name,
                kind: skill.kind.rawValue,
                revision: skill.revision,
                source: skill.source,
                scope: skill.scope
            ))
        }
        selected.sort { $0.id < $1.id }
        guard selected.count == (rule.skillIDs ?? []).count else { return nil }
        let contract = Contract(
            id: rule.id,
            name: rule.name,
            schedule: schedule,
            timeZoneIdentifier: rule.timeZoneIdentifier,
            actionSummary: rule.actionSummary,
            missedRunPolicy: rule.missedRunPolicy.rawValue,
            actionKind: actionKind.rawValue,
            authority: authority.rawValue,
            projectID: rule.projectID,
            workspacePath: automationWorkspacePath(for: rule),
            capabilities: selected,
            notificationEnabled: rule.notificationEnabled ?? false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(contract) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "automation:\(rule.id):contract:sha256=\(digest)"
    }

    public func automationWorkspacePath(for rule: DesktopAutomationRule) -> String? {
        guard let projectID = rule.projectID else { return nil }
        if let path = snapshot.projects.first(where: { $0.id == projectID })?.path, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        }
        return snapshot.domains.gitWorkspaces.first(where: { $0.projectID == projectID && $0.status == .ready })
            .map { URL(fileURLWithPath: $0.localPath, isDirectory: true).standardizedFileURL.path }
    }

    public func setAutomationPaused(id: String, paused: Bool) {
        mutateRecord(at: \.domains.automations, id: id) { rule in
            rule.status = paused ? .paused : .draft
        }
    }

    public func updateAutomation(
        id: String,
        name: String,
        schedule: String,
        timeZoneIdentifier: String,
        actionSummary: String,
        missedRunPolicy: DesktopAutomationRule.MissedRunPolicy,
        scheduleSpec: DesktopScheduleSpec,
        actionKind: DesktopAutomationActionKind,
        authority: DesktopAutomationAuthority,
        projectID: String?,
        skillIDs: [String],
        notificationEnabled: Bool
    ) -> Bool {
        let fields = [name, schedule, actionSummary].map(Self.normalized)
        let selected = Array(Set(skillIDs)).sorted()
        guard fields.allSatisfy({ !$0.isEmpty }),
              TimeZone(identifier: timeZoneIdentifier) != nil,
              (actionKind == .notification || authority != .localOnly),
              (actionKind != .skill || !selected.isEmpty),
              selected.allSatisfy({ skillID in
                  snapshot.domains.skills.contains { $0.id == skillID && $0.enabled }
              }),
              snapshot.domains.automations.contains(where: { $0.id == id }),
              !snapshot.operations.automationRuns.contains(where: { $0.automationID == id && $0.state == .running }) else { return false }
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.domains.automations.firstIndex(where: { $0.id == id }) else { return }
            snapshot.domains.automations[index].name = fields[0]
            snapshot.domains.automations[index].schedule = fields[1]
            snapshot.domains.automations[index].timeZoneIdentifier = timeZoneIdentifier
            snapshot.domains.automations[index].actionSummary = fields[2]
            snapshot.domains.automations[index].missedRunPolicy = missedRunPolicy
            snapshot.domains.automations[index].scheduleSpec = scheduleSpec
            snapshot.domains.automations[index].actionKind = actionKind
            snapshot.domains.automations[index].authority = authority
            snapshot.domains.automations[index].projectID = projectID
            snapshot.domains.automations[index].skillIDs = selected
            snapshot.domains.automations[index].toolNames = []
            snapshot.domains.automations[index].notificationEnabled = notificationEnabled
            snapshot.domains.automations[index].status = .draft
            snapshot.domains.automations[index].nextRunAtUnixMillis = nil
            snapshot.domains.automations[index].lastResult = "Edited · review required"
            snapshot.domains.automations[index].standingAuthorityApprovedAtUnixMillis = nil
            snapshot.domains.automations[index].standingAuthorityApprovalID = nil
            for runIndex in snapshot.operations.automationRuns.indices
                where snapshot.operations.automationRuns[runIndex].automationID == id
                    && [.proposed, .awaitingApproval, .approved].contains(snapshot.operations.automationRuns[runIndex].state) {
                snapshot.operations.automationRuns[runIndex].state = .cancelled
                snapshot.operations.automationRuns[runIndex].completedAtUnixMillis = timestamp
                snapshot.operations.automationRuns[runIndex].detail = "The rule changed before this occurrence ran; review the edited contract."
            }
        }
        return true
    }

    public func deleteAutomation(id: String) -> Bool {
        guard snapshot.domains.automations.contains(where: { $0.id == id }),
              !snapshot.operations.automationRuns.contains(where: { $0.automationID == id && $0.state == .running }) else { return false }
        let timestamp = now()
        mutate { snapshot in
            snapshot.domains.automations.removeAll { $0.id == id }
            for index in snapshot.operations.automationRuns.indices
                where snapshot.operations.automationRuns[index].automationID == id
                    && ![DesktopActionState.completed, .failed, .cancelled, .interrupted].contains(snapshot.operations.automationRuns[index].state) {
                snapshot.operations.automationRuns[index].state = .cancelled
                snapshot.operations.automationRuns[index].completedAtUnixMillis = timestamp
                snapshot.operations.automationRuns[index].detail = "The automation was deleted before this occurrence completed."
            }
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "automation",
                action: "deleted",
                target: "automation:\(id)",
                state: .completed,
                detail: "Removed the local rule and cancelled its unfinished occurrences. Historical receipts remain available.",
                recordedAtUnixMillis: timestamp
            ))
        }
        return true
    }

    @discardableResult
    public func recordAutomationDryRun(id: String) -> String? {
        guard snapshot.domains.automations.contains(where: { $0.id == id }) else { return nil }
        let timestamp = now()
        let run = DesktopAutomationRunRecord(
            id: UUID().uuidString.lowercased(),
            automationID: id,
            scheduledAtUnixMillis: timestamp,
            startedAtUnixMillis: timestamp,
            completedAtUnixMillis: timestamp,
            state: .completed,
            detail: "Dry run validated local schedule metadata. No tools, accounts, providers, or external effects were invoked.",
            evidenceArtifactIDs: []
        )
        let persisted = mutate { snapshot in
            snapshot.operations.automationRuns.append(run)
            snapshot.domains.automations = snapshot.domains.automations.map { automation in
                var updated = automation
                if updated.id == id { updated.lastResult = "Dry run passed" }
                return updated
            }
        }
        return persisted ? run.id : nil
    }

    public func dueAutomationIDs(atUnixMillis timestamp: Int64) -> [String] {
        snapshot.domains.automations.filter {
            $0.status == .ready && ($0.nextRunAtUnixMillis ?? Int64.max) <= timestamp
        }.sorted {
            ($0.nextRunAtUnixMillis ?? Int64.max) < ($1.nextRunAtUnixMillis ?? Int64.max)
        }.map(\.id)
    }

    @discardableResult
    public func claimAutomationRun(id: String, ownerID: String, nowUnixMillis timestamp: Int64) -> String? {
        guard let rule = snapshot.domains.automations.first(where: { $0.id == id && $0.status == .ready }),
              let scheduled = rule.nextRunAtUnixMillis,
              scheduled <= timestamp,
              let spec = rule.scheduleSpec else { return nil }
        guard (rule.skillIDs ?? []).allSatisfy({ skillID in
            snapshot.domains.skills.contains { $0.id == skillID && $0.enabled }
        }) else {
            mutateRecord(at: \.domains.automations, id: id) {
                $0.status = .paused
                $0.lastResult = "Paused · selected capability unavailable"
            }
            return nil
        }
        let key = DesktopScheduleEngine.deduplicationKey(automationID: id, scheduledAtUnixMillis: scheduled)
        guard !snapshot.operations.automationRuns.contains(where: { $0.deduplicationKey == key }) else {
            advanceAutomation(id: id, spec: spec, after: scheduled)
            return nil
        }
        guard let contractTarget = automationAuthorityTarget(for: rule) else { return nil }
        let exactTarget = "\(contractTarget):occurrence=\(scheduled)"
        let missed = timestamp - scheduled > 120_000
        let state: DesktopActionState
        let detail: String
        if missed, rule.missedRunPolicy == .skip {
            state = .completed
            detail = "Skipped a missed occurrence by policy; no action ran."
        } else if rule.authority == .askEveryRun
                    || (missed && rule.missedRunPolicy == .ask)
                    || (rule.authority == .standing && !(rule.standingAuthorityApprovalID.map {
                        isApprovalGranted(id: $0, exactTarget: contractTarget, atUnixMillis: timestamp)
                    } ?? false)) {
            state = .awaitingApproval
            detail = missed ? "A missed occurrence needs catch-up approval." : "This occurrence needs exact run approval."
        } else {
            state = .approved
            detail = "Claimed by the single desktop scheduler owner and ready to execute."
        }
        var run = DesktopAutomationRunRecord(
            id: UUID().uuidString.lowercased(),
            automationID: id,
            scheduledAtUnixMillis: scheduled,
            startedAtUnixMillis: state == .approved ? timestamp : nil,
            completedAtUnixMillis: state == .completed ? timestamp : nil,
            state: state,
            detail: detail,
            evidenceArtifactIDs: []
        )
        run.deduplicationKey = key
        run.ownerID = ownerID
        run.wasMissed = missed
        run.contractTarget = contractTarget
        run.exactTarget = exactTarget
        run.workspacePath = automationWorkspacePath(for: rule)
        let next = try? DesktopScheduleEngine.nextOccurrence(
            spec: spec,
            timeZoneIdentifier: rule.timeZoneIdentifier,
            after: missed ? timestamp : scheduled
        )
        let persisted = mutate { snapshot in
            snapshot.operations.automationRuns.append(run)
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "automation",
                action: state == .completed ? "missed-skip" : "claimed",
                target: key,
                state: state,
                detail: detail,
                recordedAtUnixMillis: timestamp
            ))
            guard let index = snapshot.domains.automations.firstIndex(where: { $0.id == id }) else { return }
            snapshot.domains.automations[index].nextRunAtUnixMillis = next ?? nil
            if next == nil { snapshot.domains.automations[index].status = .paused }
        }
        return persisted ? run.id : nil
    }

    public func attachAutomationApproval(runID: String, approvalID: String) {
        mutateRecord(at: \.operations.automationRuns, id: runID) { run in
            run.approvalID = approvalID
        }
    }

    public func automationRun(id: String) -> DesktopAutomationRunRecord? {
        snapshot.operations.automationRuns.first { $0.id == id }
    }

    public func automationRunContractIsCurrent(id: String) -> Bool {
        guard let run = automationRun(id: id),
              let rule = snapshot.domains.automations.first(where: { $0.id == run.automationID }),
              automationAuthorityTarget(for: rule) == run.contractTarget,
              automationWorkspacePath(for: rule) == run.workspacePath else { return false }
        return true
    }

    @discardableResult
    public func attachAutomationDispatch(runID: String, threadID: String, providerRunID: String) -> Bool {
        mutateRecord(at: \.operations.automationRuns, id: runID) { run in
            run.threadID = threadID
            run.providerRunID = providerRunID
            run.detail = "Dispatched one durable read-only provider run; Kaname is tracking its terminal result."
        }
    }

    public func updateAutomationNotificationState(runID: String, state: String) {
        mutateRecord(at: \.operations.automationRuns, id: runID) { $0.notificationState = String(state.prefix(160)) }
    }

    public func beginApprovedAutomationRun(id: String) -> DesktopAutomationRunRecord? {
        guard let run = automationRun(id: id), run.state == .approved || run.state == .awaitingApproval else { return nil }
        if run.state == .awaitingApproval {
            guard let approvalID = run.approvalID,
                  let exactTarget = run.exactTarget,
                  isApprovalGranted(id: approvalID, exactTarget: exactTarget) else { return nil }
        }
        let timestamp = now()
        guard mutateRecord(at: \.operations.automationRuns, id: id, change: { value in
            value.state = .running
            value.startedAtUnixMillis = timestamp
            value.detail = "Executing the resolved automation contract."
        }) else { return nil }
        return automationRun(id: id)
    }

    public func completeAutomationRun(
        id: String,
        state: DesktopActionState,
        detail: String,
        threadID: String? = nil,
        notificationState: String? = nil
    ) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.automationRuns.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.automationRuns[index].state = state
            snapshot.operations.automationRuns[index].detail = String(detail.prefix(8_192))
            snapshot.operations.automationRuns[index].completedAtUnixMillis = timestamp
            snapshot.operations.automationRuns[index].threadID = threadID
            snapshot.operations.automationRuns[index].notificationState = notificationState
            if let ruleIndex = snapshot.domains.automations.firstIndex(where: {
                $0.id == snapshot.operations.automationRuns[index].automationID
            }) {
                snapshot.domains.automations[ruleIndex].lastResult = state == .completed ? "Completed" : "Failed"
            }
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "automation",
                action: "execute",
                target: snapshot.operations.automationRuns[index].deduplicationKey ?? id,
                state: state,
                detail: String(detail.prefix(8_192)),
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    private func advanceAutomation(id: String, spec: DesktopScheduleSpec, after scheduled: Int64) {
        let next = try? DesktopScheduleEngine.nextOccurrence(
            spec: spec,
            timeZoneIdentifier: snapshot.domains.automations.first(where: { $0.id == id })?.timeZoneIdentifier ?? "UTC",
            after: scheduled
        )
        mutateRecord(at: \.domains.automations, id: id) { automation in
            automation.nextRunAtUnixMillis = next ?? nil
            if next == nil { automation.status = .paused }
        }
    }
}
