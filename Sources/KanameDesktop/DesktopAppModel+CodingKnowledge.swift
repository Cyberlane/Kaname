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
    public func codingKnowledgeLane(threadID: String) -> DesktopCodingKnowledgeLane? {
        snapshot.operations.codingKnowledgeLanes.first { $0.threadID == threadID }
    }

    public func codingWorkflow(threadID: String) -> DesktopCodingWorkflowRecord? {
        snapshot.operations.codingWorkflows.first { $0.threadID == threadID }
    }

    @discardableResult
    public func ensureCodingWorkflow(threadID: String) -> DesktopCodingWorkflowRecord? {
        guard let thread = thread(id: threadID), thread.kind == .coding else { return nil }
        if let existing = codingWorkflow(threadID: threadID) { return existing }
        let timestamp = now()
        guard mutate({ snapshot in
            Self.ensureCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                projectID: thread.projectID,
                timestamp: timestamp
            )
        }) else { return nil }
        return codingWorkflow(threadID: threadID)
    }

    @discardableResult
    public func updateCodingWorkflow(
        threadID: String,
        state: DesktopCodingWorkflowState,
        reason: String? = nil
    ) -> Bool {
        guard let thread = thread(id: threadID), thread.kind == .coding,
              let currentState = codingWorkflow(threadID: threadID)?.state,
              Self.allowsExternalCodingTransition(from: currentState, to: state) else { return false }
        let timestamp = now()
        return mutate { snapshot in
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                projectID: thread.projectID,
                state: state,
                reason: reason,
                timestamp: timestamp
            )
        }
    }

    @discardableResult
    public func replaceCodingKnowledgeContext(
        threadID: String,
        projectID: String? = nil,
        sources: [DesktopCodingKnowledgeConsultedSource]
    ) -> Bool {
        guard let thread = thread(id: threadID), thread.kind == .coding,
              sources.count <= Self.codingKnowledgeMaximumSourceCount else { return false }
        guard let boundedSources = Self.boundedCodingKnowledgeSources(sources) else { return false }
        let timestamp = now()
        return mutate { snapshot in
            let laneIndex: Int
            if let index = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }) {
                laneIndex = index
            } else {
                let lane = DesktopCodingKnowledgeLane(
                    projectID: projectID ?? thread.projectID,
                    threadID: threadID,
                    createdAtUnixMillis: timestamp,
                    updatedAtUnixMillis: timestamp
                )
                snapshot.operations.codingKnowledgeLanes.append(lane)
                laneIndex = snapshot.operations.codingKnowledgeLanes.count - 1
            }
            snapshot.operations.codingKnowledgeLanes[laneIndex].consultedSources = boundedSources
            snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            if snapshot.operations.codingKnowledgeLanes[laneIndex].projectID == nil {
                snapshot.operations.codingKnowledgeLanes[laneIndex].projectID = projectID ?? thread.projectID
            }
            Self.ensureCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                projectID: projectID ?? thread.projectID,
                timestamp: timestamp
            )
        }
    }

    @discardableResult
    public func addCodingKnowledgeCandidate(
        threadID: String,
        category: DesktopCodingKnowledgeCandidateCategory,
        title: String,
        detail: String,
        evidenceDigest: String? = nil
    ) -> String? {
        guard let thread = thread(id: threadID), thread.kind == .coding else { return nil }
        let cleanTitle = Self.normalized(title)
        let cleanDetail = Self.normalized(detail)
        let cleanEvidence = evidenceDigest.map(Self.normalized)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= Self.codingKnowledgeMaximumTitleBytes,
              !cleanDetail.isEmpty, cleanDetail.utf8.count <= Self.codingKnowledgeMaximumDetailBytes,
              cleanEvidence?.utf8.count ?? 0 <= Self.codingKnowledgeMaximumDigestBytes else { return nil }
        let timestamp = now()
        let candidate = DesktopCodingKnowledgeCandidate(
            category: category,
            title: cleanTitle,
            detail: cleanDetail,
            evidenceDigest: cleanEvidence
        )
        var result: String?
        let persisted = mutate { snapshot in
            let laneIndex: Int
            if let index = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }) {
                laneIndex = index
            } else {
                snapshot.operations.codingKnowledgeLanes.append(.init(
                    projectID: thread.projectID,
                    threadID: threadID,
                    createdAtUnixMillis: timestamp,
                    updatedAtUnixMillis: timestamp
                ))
                laneIndex = snapshot.operations.codingKnowledgeLanes.count - 1
            }
            let duplicate = snapshot.operations.codingKnowledgeLanes[laneIndex].candidates.contains {
                $0.category == category && $0.title == cleanTitle && $0.detail == cleanDetail
                    && $0.evidenceDigest == cleanEvidence
            }
            guard !duplicate,
                  snapshot.operations.codingKnowledgeLanes[laneIndex].candidates.count < Self.codingKnowledgeMaximumCandidateCount else { return }
            snapshot.operations.codingKnowledgeLanes[laneIndex].candidates.append(candidate)
            snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            Self.ensureCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                projectID: thread.projectID,
                timestamp: timestamp
            )
            result = candidate.id
        }
        return persisted ? result : nil
    }

    @discardableResult
    public func markCodingKnowledgeNeedsReview(threadID: String, reason: String) -> Bool {
        updateCodingKnowledgeDisposition(threadID: threadID, disposition: .needsReview, reason: reason)
    }

    @discardableResult
    public func linkCodingKnowledge(
        threadID: String,
        proposalID: String? = nil,
        writeID: String? = nil
    ) -> Bool {
        let cleanProposal = proposalID.map(Self.normalized)
        let cleanWrite = writeID.map(Self.normalized)
        guard cleanProposal?.isEmpty != true, cleanProposal?.utf8.count ?? 0 <= 256,
              cleanWrite?.isEmpty != true, cleanWrite?.utf8.count ?? 0 <= 256,
              thread(id: threadID)?.kind == .coding,
              codingWorkflow(threadID: threadID)?.state == .updatingKnowledge,
              Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
              codingKnowledgeLane(threadID: threadID) != nil,
              cleanProposal != nil || cleanWrite != nil else { return false }
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            guard let laneIndex = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }),
                  snapshot.threads.first(where: { $0.id == threadID })?.kind == .coding,
                  snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge,
                  Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID) else { return }
            snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID = cleanProposal ?? snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID
            snapshot.operations.codingKnowledgeLanes[laneIndex].writeID = cleanWrite ?? snapshot.operations.codingKnowledgeLanes[laneIndex].writeID
            snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .proposed
            snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "Knowledge update proposal is linked and awaiting review."
            snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .updatingKnowledge,
                reason: "Knowledge update proposal is linked and awaiting review.",
                timestamp: timestamp
            )
            didApply = true
        }
        return didApply && persisted
    }

    @discardableResult
    public func waiveCodingKnowledge(threadID: String, reason: String) -> Bool {
        guard let cleanReason = validatedCodingKnowledgeReason(threadID: threadID, reason: reason) else {
            return false
        }
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            guard let laneIndex = Self.codingKnowledgeLaneIndexForMutation(
                in: snapshot,
                threadID: threadID
            ) else { return }
            Self.setCodingKnowledgeLaneDisposition(
                in: &snapshot,
                laneIndex: laneIndex,
                disposition: .waived,
                reason: cleanReason,
                timestamp: timestamp
            )
            if let proposalID = snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID,
               let proposalIndex = snapshot.operations.knowledgeProposals.firstIndex(where: { $0.id == proposalID }),
               snapshot.operations.knowledgeProposals[proposalIndex].state != .reconciled {
                snapshot.operations.knowledgeProposals[proposalIndex].state = .cancelled
            }
            if let writeID = snapshot.operations.codingKnowledgeLanes[laneIndex].writeID,
               let writeIndex = snapshot.operations.knowledgeWrites.firstIndex(where: { $0.id == writeID }),
               snapshot.operations.knowledgeWrites[writeIndex].state != .reconciled {
                snapshot.operations.knowledgeWrites[writeIndex].state = .cancelled
                if let approvalID = snapshot.operations.knowledgeWrites[writeIndex].approvalID,
                   let approvalIndex = snapshot.operations.approvals.firstIndex(where: {
                       $0.id == approvalID && $0.state == .awaitingApproval
                   }) {
                    snapshot.operations.approvals[approvalIndex].state = .cancelled
                }
            }
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .completed,
                reason: "Knowledge update waived: \(cleanReason)",
                timestamp: timestamp
            )
            if let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
                snapshot.threads[threadIndex].attention = .completed
                snapshot.threads[threadIndex].summary = "Implementation accepted locally. Knowledge update waived: \(cleanReason)"
                snapshot.threads[threadIndex].unread = false
                snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
            }
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "knowledge",
                action: "coding knowledge waived",
                target: threadID,
                state: .completed,
                detail: cleanReason,
                recordedAtUnixMillis: timestamp
            ))
            didApply = true
        }
        return didApply && persisted
    }

    @discardableResult
    public func beginCodingKnowledgeRevision(threadID: String) -> Bool {
        guard thread(id: threadID)?.kind == .coding,
              codingWorkflow(threadID: threadID)?.state == .updatingKnowledge,
              Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
              let lane = codingKnowledgeLane(threadID: threadID),
              let writeID = lane.writeID,
              let write = snapshot.operations.knowledgeWrites.first(where: { $0.id == writeID }) else { return false }
        let approvalState = write.approvalID.flatMap { approvalID in
            snapshot.operations.approvals.first(where: { $0.id == approvalID })?.state
        }
        guard lane.disposition == .conflict || write.state == .failed
                || approvalState == .rejected || approvalState == .cancelled else { return false }
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            guard let laneIndex = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }),
                  snapshot.operations.codingKnowledgeLanes[laneIndex].writeID == writeID,
                  snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge,
                  Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID) else { return }
            snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID = nil
            snapshot.operations.codingKnowledgeLanes[laneIndex].writeID = nil
            snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .needsReview
            snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "The previous proposal was rejected or conflicted; inspect the current note and prepare a revised diff."
            snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .updatingKnowledge,
                reason: "A revised knowledge proposal is required from the current note revision.",
                timestamp: timestamp
            )
            didApply = true
        }
        return didApply && persisted
    }

    @discardableResult
    private func updateCodingKnowledgeDisposition(
        threadID: String,
        disposition: DesktopCodingKnowledgeDisposition,
        reason: String
    ) -> Bool {
        guard let cleanReason = validatedCodingKnowledgeReason(threadID: threadID, reason: reason) else {
            return false
        }
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            guard let laneIndex = Self.codingKnowledgeLaneIndexForMutation(
                in: snapshot,
                threadID: threadID
            ) else { return }
            Self.setCodingKnowledgeLaneDisposition(
                in: &snapshot,
                laneIndex: laneIndex,
                disposition: disposition,
                reason: cleanReason,
                timestamp: timestamp
            )
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .updatingKnowledge,
                reason: cleanReason,
                timestamp: timestamp
            )
            didApply = true
        }
        return didApply && persisted
    }

    private func validatedCodingKnowledgeReason(threadID: String, reason: String) -> String? {
        let cleanReason = Self.normalized(reason)
        guard thread(id: threadID)?.kind == .coding,
              codingWorkflow(threadID: threadID)?.state == .updatingKnowledge,
              Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
              codingKnowledgeLane(threadID: threadID) != nil,
              !cleanReason.isEmpty,
              cleanReason.utf8.count <= Self.codingKnowledgeMaximumReasonBytes else { return nil }
        return cleanReason
    }

    private static func codingKnowledgeLaneIndexForMutation(
        in snapshot: DesktopAppSnapshot,
        threadID: String
    ) -> Int? {
        guard snapshot.threads.first(where: { $0.id == threadID })?.kind == .coding,
              snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge,
              hasAcceptedCodingWorktree(in: snapshot, threadID: threadID) else { return nil }
        return snapshot.operations.codingKnowledgeLanes.firstIndex { $0.threadID == threadID }
    }

    private static func setCodingKnowledgeLaneDisposition(
        in snapshot: inout DesktopAppSnapshot,
        laneIndex: Int,
        disposition: DesktopCodingKnowledgeDisposition,
        reason: String,
        timestamp: Int64
    ) {
        snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = disposition
        snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = reason
        snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
    }

    private static let codingKnowledgeMaximumSourceCount = 64
    private static let codingKnowledgeMaximumCandidateCount = 64
    private static let codingKnowledgeMaximumSourceIDBytes = 256
    private static let codingKnowledgeMaximumTitleBytes = 240
    private static let codingKnowledgeMaximumPathBytes = 2_048
    private static let codingKnowledgeMaximumDigestBytes = 256
    private static let codingKnowledgeMaximumProvenanceBytes = 1_024
    private static let codingKnowledgeMaximumExcerptBytes = 8_192
    private static let codingKnowledgeMaximumSummaryBytes = 2_048
    private static let codingKnowledgeMaximumDetailBytes = 8_192
    static let codingKnowledgeMaximumReasonBytes = 2_048

    private static func allowsExternalCodingTransition(
        from current: DesktopCodingWorkflowState,
        to next: DesktopCodingWorkflowState
    ) -> Bool {
        if current == next { return true }
        if next == .failed && current != .completed { return true }
        return switch (current, next) {
        case (.awaitingPlanApproval, .preparingImplementation),
             (.awaitingReview, .reviewingEvidence),
             (.reviewingEvidence, .awaitingReview),
             (.awaitingAcceptance, .reviewingEvidence):
            true
        default:
            false
        }
    }

    private static func boundedCodingKnowledgeSources(
        _ sources: [DesktopCodingKnowledgeConsultedSource]
    ) -> [DesktopCodingKnowledgeConsultedSource]? {
        var seen = Set<String>()
        var bounded: [DesktopCodingKnowledgeConsultedSource] = []
        bounded.reserveCapacity(sources.count)
        for source in sources {
            guard !normalized(source.sourceID).isEmpty, source.sourceID.utf8.count <= codingKnowledgeMaximumSourceIDBytes,
                  !normalized(source.title).isEmpty, source.title.utf8.count <= codingKnowledgeMaximumTitleBytes,
                  !normalized(source.path).isEmpty, source.path.utf8.count <= codingKnowledgeMaximumPathBytes,
                  !normalized(source.digest).isEmpty, source.digest.utf8.count <= codingKnowledgeMaximumDigestBytes,
                  !normalized(source.provenance).isEmpty, source.provenance.utf8.count <= codingKnowledgeMaximumProvenanceBytes,
                  source.excerpt.utf8.count <= codingKnowledgeMaximumExcerptBytes,
                  source.summary.utf8.count <= codingKnowledgeMaximumSummaryBytes else { return nil }
            let key = "\(source.sourceID)|\(source.path)|\(source.digest)"
            guard seen.insert(key).inserted else { continue }
            bounded.append(source)
            if bounded.count == codingKnowledgeMaximumSourceCount { break }
        }
        return bounded
    }
}
