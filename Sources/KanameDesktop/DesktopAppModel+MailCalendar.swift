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
    public func saveEmailDraft(
        id: String? = nil,
        accountID: String?,
        recipients: String,
        subject: String,
        body: String
    ) -> String? {
        let cleanSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSubject.isEmpty || !cleanBody.isEmpty,
              cleanSubject.utf8.count <= 998, cleanBody.utf8.count <= 100_000 else { return nil }
        let draft = DesktopEmailDraft(
            id: id ?? UUID().uuidString.lowercased(),
            accountID: accountID,
            recipients: recipients.trimmingCharacters(in: .whitespacesAndNewlines),
            subject: cleanSubject,
            body: cleanBody,
            status: .draft,
            updatedAtUnixMillis: now()
        )
        mutate { snapshot in
            if let index = snapshot.domains.emailDrafts.firstIndex(where: { $0.id == draft.id }) {
                snapshot.domains.emailDrafts[index] = draft
            } else {
                snapshot.domains.emailDrafts.append(draft)
            }
        }
        return draft.id
    }

    @discardableResult
    public func recordMailAction(
        accountID: String,
        accountIdentity: String,
        threadID: String?,
        kind: DesktopMailActionRecord.Kind,
        preview: String,
        exactTarget: String,
        standingRuleID: String? = nil
    ) -> String? {
        let cleanPreview = Self.normalized(preview)
        let cleanTarget = Self.normalized(exactTarget)
        guard !accountID.isEmpty, !accountIdentity.isEmpty, !cleanPreview.isEmpty, !cleanTarget.isEmpty,
              cleanPreview.utf8.count <= 8_192, cleanTarget.utf8.count <= 2_048 else { return nil }
        let action = DesktopMailActionRecord(
            id: UUID().uuidString.lowercased(),
            accountID: accountID,
            accountIdentity: accountIdentity,
            threadID: threadID,
            kind: kind,
            preview: cleanPreview,
            exactTarget: cleanTarget,
            approvalID: nil,
            standingRuleID: standingRuleID,
            state: standingRuleID == nil ? .proposed : .approved,
            remoteReceipt: nil,
            createdAtUnixMillis: now(),
            reconciledAtUnixMillis: nil
        )
        mutate { $0.operations.mailActions.append(action) }
        return action.id
    }

    public func attachMailApproval(actionID: String, approvalID: String) {
        mutateRecord(at: \.operations.mailActions, id: actionID) { action in
            action.approvalID = approvalID
            action.state = .awaitingApproval
        }
    }

    public func reconcileMailAction(id: String, state: DesktopActionState, remoteReceipt: String?) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.mailActions.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.mailActions[index].state = state
            snapshot.operations.mailActions[index].remoteReceipt = remoteReceipt
            snapshot.operations.mailActions[index].reconciledAtUnixMillis = timestamp
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "gmail",
                action: snapshot.operations.mailActions[index].kind.rawValue,
                target: snapshot.operations.mailActions[index].exactTarget,
                state: state,
                detail: remoteReceipt ?? "Remote reconciliation did not complete.",
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    public func resumableMailAction(
        accountID: String,
        threadID: String,
        exactTarget: String
    ) -> DesktopMailActionRecord? {
        snapshot.operations.mailActions
            .filter {
                $0.accountID == accountID
                    && $0.threadID == threadID
                    && $0.exactTarget == exactTarget
                    && $0.standingRuleID == nil
                    && ($0.state == .proposed || $0.state == .awaitingApproval)
            }
            .compactMap { action -> (record: DesktopMailActionRecord, priority: Int)? in
                guard let approvalID = action.approvalID else {
                    return action.state == .proposed ? (action, 0) : nil
                }
                guard action.state == .awaitingApproval,
                      let approval = snapshot.operations.approvals.first(where: { $0.id == approvalID }),
                      approval.exactTarget == action.exactTarget else { return nil }
                switch approval.state {
                case .approved:
                    return (action, 2)
                case .awaitingApproval:
                    return (action, 1)
                default:
                    return nil
                }
            }
            .max {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.record.createdAtUnixMillis < $1.record.createdAtUnixMillis
            }?
            .record
    }

    @discardableResult
    public func createMailStandingRule(
        accountID: String,
        accountIdentity: String,
        name: String,
        query: String,
        action: DesktopMailActionRecord.Kind
    ) -> String? {
        let cleanName = Self.normalized(name)
        let cleanQuery = Self.normalized(query)
        guard !accountID.isEmpty, !accountIdentity.isEmpty, !cleanName.isEmpty, !cleanQuery.isEmpty,
              action == .archive || action == .labels else { return nil }
        let rule = DesktopMailStandingRule(
            id: UUID().uuidString.lowercased(),
            accountID: accountID,
            accountIdentity: accountIdentity,
            name: cleanName,
            query: cleanQuery,
            action: action,
            enabled: true,
            createdAtUnixMillis: now()
        )
        mutate { $0.operations.mailStandingRules.append(rule) }
        return rule.id
    }

    public func setMailStandingRuleEnabled(id: String, enabled: Bool) {
        mutate { snapshot in
            guard let index = snapshot.operations.mailStandingRules.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.mailStandingRules[index].enabled = enabled
        }
    }

    public func replaceMailAttention(_ records: [DesktopMailAttentionRecord]) {
        mutate { $0.operations.mailAttention = records }
    }

    public func reconcileMailAttention(
        _ entries: [(accountID: String, threadID: String, accountIdentity: String, sender: String, subject: String, unread: Bool)]
    ) {
        let timestamp = now()
        mutate { snapshot in
            snapshot.operations.mailAttention = entries.map {
                DesktopMailAttentionRecord(
                    accountID: $0.accountID,
                    threadID: $0.threadID,
                    accountIdentity: $0.accountIdentity,
                    sender: $0.sender,
                    subject: $0.subject,
                    unread: $0.unread,
                    updatedAtUnixMillis: timestamp
                )
            }
        }
    }

    public func markEmailDraft(id: String, status: DesktopRecordState) {
        mutateRecord(at: \.domains.emailDrafts, id: id) { draft in
            draft.status = status
            draft.updatedAtUnixMillis = now()
        }
    }

    @discardableResult
    public func createCalendarProposal(
        accountID: String? = nil,
        calendarSourceID: String? = nil,
        title: String,
        startAtUnixMillis: Int64,
        durationMinutes: Int,
        timeZoneIdentifier: String,
        recurrence: String,
        isAllDay: Bool = false,
        mutationKind: DesktopCalendarProposal.MutationKind = .create,
        eventExternalID: String? = nil,
        seriesMasterExternalID: String? = nil,
        eventRevision: String? = nil,
        originalTitle: String? = nil,
        originalStartAtUnixMillis: Int64? = nil,
        originalEndAtUnixMillis: Int64? = nil,
        originalTimeZoneIdentifier: String? = nil,
        originalRecurrence: [String]? = nil,
        originalIsAllDay: Bool? = nil,
        seriesMasterRevision: String? = nil,
        seriesMasterRecurrence: [String]? = nil,
        seriesMasterStartAtUnixMillis: Int64? = nil,
        recurrenceScope: String? = nil
    ) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= 200,
              (1...10_080).contains(durationMinutes),
              TimeZone(identifier: timeZoneIdentifier) != nil else { return nil }
        var proposal = DesktopCalendarProposal(
            id: UUID().uuidString.lowercased(),
            accountID: accountID,
            calendarSourceID: calendarSourceID,
            title: cleanTitle,
            startAtUnixMillis: startAtUnixMillis,
            durationMinutes: durationMinutes,
            timeZoneIdentifier: timeZoneIdentifier,
            recurrence: recurrence.trimmingCharacters(in: .whitespacesAndNewlines),
            status: .proposed
        )
        proposal.mutationKind = mutationKind
        proposal.isAllDay = isAllDay
        proposal.eventExternalID = eventExternalID
        proposal.seriesMasterExternalID = seriesMasterExternalID
        proposal.eventRevision = eventRevision
        proposal.originalTitle = originalTitle
        proposal.originalStartAtUnixMillis = originalStartAtUnixMillis
        proposal.originalEndAtUnixMillis = originalEndAtUnixMillis
        proposal.originalTimeZoneIdentifier = originalTimeZoneIdentifier
        proposal.originalRecurrence = originalRecurrence
        proposal.originalIsAllDay = originalIsAllDay
        proposal.seriesMasterRevision = seriesMasterRevision
        proposal.seriesMasterRecurrence = seriesMasterRecurrence
        proposal.seriesMasterStartAtUnixMillis = seriesMasterStartAtUnixMillis
        proposal.recurrenceScope = recurrenceScope
        proposal.mutationPhase = "prepared"
        mutate { $0.domains.calendarProposals.append(proposal) }
        return proposal.id
    }

    public func prepareCalendarProposal(id: String, exactTarget: String) {
        mutateRecord(at: \.domains.calendarProposals, id: id) { proposal in
            proposal.exactTarget = String(exactTarget.prefix(2_048))
            proposal.approvalID = nil
            proposal.remoteReceipt = nil
            proposal.reconciledAtUnixMillis = nil
            proposal.mutationPhase = "prepared"
            proposal.status = .needsReview
        }
    }

    public func attachCalendarApproval(proposalID: String, approvalID: String) {
        mutateRecord(at: \.domains.calendarProposals, id: proposalID) { proposal in
            proposal.approvalID = approvalID
            proposal.status = .waiting
        }
    }

    public func beginCalendarProposalExecution(id: String) -> Bool {
        guard let proposal = snapshot.domains.calendarProposals.first(where: { $0.id == id }),
              proposal.status == .waiting || proposal.status == .running,
              let approvalID = proposal.approvalID,
              let exactTarget = proposal.exactTarget,
              exactEffectIsAuthorized(approvalID: approvalID, target: exactTarget) else { return false }
        mutateRecord(at: \.domains.calendarProposals, id: id) { $0.status = .running }
        return true
    }

    public func recordCalendarMutationPhase(id: String, phase: String) {
        mutateRecord(at: \.domains.calendarProposals, id: id) {
            $0.mutationPhase = String(phase.prefix(80))
            $0.status = .running
        }
    }

    public func recordCalendarMutationUncertain(id: String, detail: String) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.domains.calendarProposals.firstIndex(where: { $0.id == id }) else { return }
            snapshot.domains.calendarProposals[index].status = .running
            snapshot.domains.calendarProposals[index].remoteReceipt = "Outcome unknown. Reconcile before retrying: \(String(detail.prefix(8_000)))"
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "calendar",
                action: "reconcile-required",
                target: snapshot.domains.calendarProposals[index].exactTarget ?? "calendar proposal \(id)",
                state: .running,
                detail: "A calendar request may have reached the provider. Kaname retained the operation identity and stopped until its remote postconditions are reconciled.",
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    public func reconcileCalendarProposal(id: String, state: DesktopActionState, receipt: String) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.domains.calendarProposals.firstIndex(where: { $0.id == id }) else { return }
            snapshot.domains.calendarProposals[index].status = state == .reconciled ? .ready : .failed
            if state == .reconciled {
                snapshot.domains.calendarProposals[index].mutationPhase = "complete"
            }
            snapshot.domains.calendarProposals[index].remoteReceipt = String(receipt.prefix(8_192))
            snapshot.domains.calendarProposals[index].reconciledAtUnixMillis = timestamp
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "calendar",
                action: snapshot.domains.calendarProposals[index].mutationKind?.rawValue ?? "create",
                target: snapshot.domains.calendarProposals[index].exactTarget ?? "calendar proposal \(id)",
                state: state,
                detail: String(receipt.prefix(8_192)),
                recordedAtUnixMillis: timestamp
            ))
        }
    }
}
