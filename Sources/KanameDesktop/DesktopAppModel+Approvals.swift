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
    public func isApprovalGranted(id: String, exactTarget: String, atUnixMillis timestamp: Int64? = nil) -> Bool {
        let checkedAt = timestamp ?? now()
        guard let approval = snapshot.operations.approvals.first(where: { $0.id == id }),
              approval.state == .approved,
              approval.exactTarget == exactTarget else { return false }
        return approval.expiresAtUnixMillis.map { $0 >= checkedAt } ?? true
    }

    /// Marks a successfully executed exact action as consumed. Consequential
    /// one-shot grants must not remain reusable merely because their target is
    /// still byte-for-byte identical after execution.
    @discardableResult
    public func consumeApproval(id: String, exactTarget: String) -> Bool {
        let timestamp = now()
        var consumed = false
        let persisted = mutate { snapshot in
            guard let index = snapshot.operations.approvals.firstIndex(where: { $0.id == id }),
                  snapshot.operations.approvals[index].state == .approved,
                  snapshot.operations.approvals[index].exactTarget == exactTarget,
                  snapshot.operations.approvals[index].expiresAtUnixMillis.map({ $0 >= timestamp }) ?? true else {
                return
            }
            snapshot.operations.approvals[index].state = .completed
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "approval",
                action: "consumed",
                target: exactTarget,
                state: .completed,
                detail: "The exact local approval was consumed after the action completed.",
                recordedAtUnixMillis: timestamp
            ))
            consumed = true
        }
        return persisted && consumed
    }

    public func exactEffectIsAuthorized(approvalID: String, target: String) -> Bool {
        !snapshot.preferences.safeMode && isApprovalGranted(id: approvalID, exactTarget: target)
    }

    @discardableResult
    public func createApproval(
        threadID: String?,
        title: String,
        exactTarget: String,
        consequence: String,
        dataLeavingDevice: String,
        reversible: Bool,
        expiresAtUnixMillis: Int64?
    ) -> String? {
        let required = (
            title: Self.normalized(title),
            target: Self.normalized(exactTarget),
            consequence: Self.normalized(consequence)
        )
        guard !required.title.isEmpty, !required.target.isEmpty, !required.consequence.isEmpty else { return nil }
        let approval = DesktopApprovalRecord(
            id: UUID().uuidString.lowercased(),
            threadID: threadID,
            title: required.title,
            exactTarget: required.target,
            consequence: required.consequence,
            dataLeavingDevice: Self.normalized(dataLeavingDevice),
            reversible: reversible,
            state: .awaitingApproval,
            requestedAtUnixMillis: now(),
            expiresAtUnixMillis: expiresAtUnixMillis
        )
        mutate { snapshot in
            snapshot.operations.approvals.append(approval)
            snapshot.operations.audit.append(
                DesktopAuditRecord(
                    id: UUID().uuidString.lowercased(),
                    domain: "approval",
                    action: "requested",
                    target: approval.exactTarget,
                    state: .awaitingApproval,
                    detail: approval.consequence,
                    recordedAtUnixMillis: approval.requestedAtUnixMillis
                )
            )
        }
        return approval.id
    }

    public func resolveApproval(id: String, approved: Bool) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.approvals.firstIndex(where: { $0.id == id }),
                  snapshot.operations.approvals[index].state == .awaitingApproval else { return }
            if snapshot.operations.approvals[index].expiresAtUnixMillis.map({ $0 < timestamp }) ?? false {
                snapshot.operations.approvals[index].state = .cancelled
                Self.applyKnowledgeApprovalDecision(
                    in: &snapshot,
                    approvalID: id,
                    state: .cancelled,
                    timestamp: timestamp
                )
                snapshot.operations.audit.append(DesktopAuditRecord(
                    id: UUID().uuidString.lowercased(),
                    domain: "approval",
                    action: "expired",
                    target: snapshot.operations.approvals[index].exactTarget,
                    state: .cancelled,
                    detail: "The approval expired before a decision; no action was dispatched.",
                    recordedAtUnixMillis: timestamp
                ))
                return
            }
            let state: DesktopActionState = approved ? .approved : .rejected
            snapshot.operations.approvals[index].state = state
            Self.applyKnowledgeApprovalDecision(
                in: &snapshot,
                approvalID: id,
                state: state,
                timestamp: timestamp
            )
            snapshot.operations.audit.append(
                DesktopAuditRecord(
                    id: UUID().uuidString.lowercased(),
                    domain: "approval",
                    action: approved ? "approved" : "rejected",
                    target: snapshot.operations.approvals[index].exactTarget,
                    state: state,
                    detail: "Local approval decision recorded; no external action was dispatched.",
                    recordedAtUnixMillis: timestamp
                )
            )
        }
    }

    private static func applyKnowledgeApprovalDecision(
        in snapshot: inout DesktopAppSnapshot,
        approvalID: String,
        state: DesktopActionState,
        timestamp: Int64
    ) {
        let writeIndexes = snapshot.operations.knowledgeWrites.indices.filter {
            snapshot.operations.knowledgeWrites[$0].approvalID == approvalID
        }
        for writeIndex in writeIndexes {
            let writeID = snapshot.operations.knowledgeWrites[writeIndex].id
            let proposalID = snapshot.operations.knowledgeWrites[writeIndex].proposalID
            snapshot.operations.knowledgeWrites[writeIndex].state = state
            if let proposalIndex = snapshot.operations.knowledgeProposals.firstIndex(where: { $0.id == proposalID }) {
                snapshot.operations.knowledgeProposals[proposalIndex].state = state
            }
            for laneIndex in snapshot.operations.codingKnowledgeLanes.indices
            where snapshot.operations.codingKnowledgeLanes[laneIndex].writeID == writeID
                || snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID == proposalID {
                let threadID = snapshot.operations.codingKnowledgeLanes[laneIndex].threadID
                guard hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
                      snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge else { continue }
                if state == .approved {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .proposed
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "The exact knowledge write is approved but has not been applied or reconciled."
                } else if state == .rejected || state == .cancelled {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .needsReview
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = state == .rejected
                        ? "The exact knowledge write was rejected; revise it or record a reasoned waiver."
                        : "The exact knowledge-write approval expired; request a revised proposal or record a reasoned waiver."
                }
                snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            }
        }
    }
}
