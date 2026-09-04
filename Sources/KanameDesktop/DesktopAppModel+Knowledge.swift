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
    public func createResearch(title: String, question: String) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanQuestion.isEmpty,
              cleanTitle.utf8.count <= 160, cleanQuestion.utf8.count <= 4_000 else { return nil }
        let record = DesktopResearchRecord(
            id: UUID().uuidString.lowercased(),
            title: cleanTitle,
            question: cleanQuestion,
            status: .draft,
            sourceCount: 0,
            updatedAtUnixMillis: now()
        )
        mutate { $0.domains.research.append(record) }
        return record.id
    }

    /// Adds a SKILL.md discovered on disk to the catalog so the Skills screen,
    /// composer picker, and search all see the same entry. `registryName` binds
    /// the catalog record to the on-disk skill used at run time.
    @discardableResult
    public func registerDiscoveredSkill(registryName: String, path: String, description: String) -> String? {
        let cleanName = Self.normalized(registryName)
        guard !cleanName.isEmpty else { return nil }
        if let existing = snapshot.domains.skills.first(where: { $0.registryName == cleanName }) { return existing.id }
        let record = DesktopSkillRecord(
            id: "skill-\(Self.stableLocalDigest(cleanName + "\u{0}" + path).prefix(16))",
            name: cleanName,
            registryName: cleanName,
            kind: .skill,
            scope: path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/.") ? "user" : "workspace",
            source: path,
            revision: Self.stableLocalDigest(description).prefix(12).description,
            status: .ready,
            enabled: true
        )
        let persisted = mutate { snapshot in
            snapshot.domains.skills.append(record)
        }
        return persisted ? record.id : nil
    }

    public func setSkillEnabled(id: String, enabled: Bool) {
        mutateRecord(at: \.domains.skills, id: id) { skill in
            skill.enabled = enabled
        }
    }

    @discardableResult
    public func addResearchSource(
        researchID: String,
        title: String,
        location: String,
        publisher: String,
        isPrimary: Bool,
        note: String
    ) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.domains.research.contains(where: { $0.id == researchID }),
              !cleanTitle.isEmpty, !cleanLocation.isEmpty,
              cleanTitle.utf8.count <= 300, cleanLocation.utf8.count <= 4_096 else { return nil }
        let source = DesktopResearchSource(
            id: UUID().uuidString.lowercased(),
            researchID: researchID,
            title: cleanTitle,
            location: cleanLocation,
            publisher: publisher.trimmingCharacters(in: .whitespacesAndNewlines),
            isPrimary: isPrimary,
            retrievedAtUnixMillis: now(),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        mutate { snapshot in
            snapshot.operations.researchSources.append(source)
            if let index = snapshot.domains.research.firstIndex(where: { $0.id == researchID }) {
                snapshot.domains.research[index].sourceCount += 1
                snapshot.domains.research[index].updatedAtUnixMillis = source.retrievedAtUnixMillis
            }
        }
        return source.id
    }

    @discardableResult
    public func createKnowledgeProposal(
        sourceID: String?,
        title: String,
        target: String,
        summary: String,
        proposedContent: String,
        baseRevision: String
    ) -> String? {
        let cleanTitle = Self.normalized(title)
        let cleanTarget = Self.normalized(target)
        let cleanSummary = Self.normalized(summary)
        let cleanBaseRevision = Self.normalized(baseRevision)
        let targetComponents = cleanTarget.split(separator: "/", omittingEmptySubsequences: false)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= 240,
              !cleanTarget.isEmpty, cleanTarget.utf8.count <= 2_048, !cleanTarget.hasPrefix("/"),
              !targetComponents.contains("."), !targetComponents.contains(".."), !targetComponents.contains(""),
              cleanSummary.utf8.count <= 16_384,
              !Self.normalized(proposedContent).isEmpty, proposedContent.utf8.count <= 2_097_152,
              !cleanBaseRevision.isEmpty, cleanBaseRevision.utf8.count <= 256 else { return nil }
        let proposal = DesktopKnowledgeProposal(
            id: UUID().uuidString.lowercased(),
            knowledgeSourceID: sourceID,
            title: cleanTitle,
            target: cleanTarget,
            summary: cleanSummary,
            proposedContent: proposedContent,
            baseRevision: cleanBaseRevision,
            state: .proposed,
            createdAtUnixMillis: now()
        )
        return mutate({ $0.operations.knowledgeProposals.append(proposal) }) ? proposal.id : nil
    }

    @discardableResult
    public func addVaultScope(path: String, sourceID: String?, canWrite: Bool) -> String? {
        let cleanPath = Self.normalized(path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = cleanPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !cleanPath.isEmpty, !cleanPath.hasPrefix("/"), cleanPath.utf8.count <= 2_048,
              !components.contains("."), !components.contains(".."), !components.contains("") else { return nil }
        if let existing = snapshot.operations.vaultScopes.first(where: { $0.path == cleanPath }) {
            mutate { value in
                guard let index = value.operations.vaultScopes.firstIndex(where: { $0.id == existing.id }) else { return }
                value.operations.vaultScopes[index].canRead = true
                value.operations.vaultScopes[index].canWrite = canWrite
                value.operations.vaultScopes[index].sourceID = sourceID
            }
            return existing.id
        }
        let scope = DesktopVaultScopeRecord(
            id: UUID().uuidString.lowercased(),
            sourceID: sourceID,
            path: cleanPath,
            canRead: true,
            canWrite: canWrite,
            lastReconciledAtUnixMillis: nil
        )
        mutate { $0.operations.vaultScopes.append(scope) }
        return scope.id
    }

    public func removeVaultScope(id: String) {
        mutate { $0.operations.vaultScopes.removeAll { $0.id == id } }
    }

    public func recordKnowledgeDocument(_ document: DesktopKnowledgeDocumentRecord) {
        mutate { snapshot in
            if let index = snapshot.operations.knowledgeDocuments.firstIndex(where: { $0.path == document.path }) {
                let existing = snapshot.operations.knowledgeDocuments[index]
                var reconciled = document
                reconciled.role = existing.role ?? document.role
                reconciled.projectID = existing.projectID ?? document.projectID
                snapshot.operations.knowledgeDocuments[index] = reconciled
            } else {
                snapshot.operations.knowledgeDocuments.append(document)
            }
            for index in snapshot.operations.vaultScopes.indices where
                document.path == snapshot.operations.vaultScopes[index].path
                    || document.path.hasPrefix(snapshot.operations.vaultScopes[index].path + "/") {
                snapshot.operations.vaultScopes[index].lastReconciledAtUnixMillis = document.lastReadAtUnixMillis
            }
        }
    }

    public func classifyKnowledgeDocument(
        path: String,
        projectID: String?,
        role: DesktopKnowledgeDocumentRecord.Role?
    ) {
        guard let id = snapshot.operations.knowledgeDocuments.first(where: { $0.path == path })?.id else { return }
        mutateRecord(at: \.operations.knowledgeDocuments, id: id) { document in
            document.projectID = projectID
            document.role = role
        }
    }

    @discardableResult
    public func recordKnowledgeWrite(
        proposalID: String,
        targetPath: String,
        baseDigest: String,
        proposedDigest: String,
        diffSummary: String,
        unifiedDiff: String
    ) -> String? {
        let cleanTargetPath = Self.normalized(targetPath)
        let cleanBaseDigest = Self.normalized(baseDigest)
        let cleanProposedDigest = Self.normalized(proposedDigest)
        guard let proposal = snapshot.operations.knowledgeProposals.first(where: {
            $0.id == proposalID && $0.state == .proposed
        }),
              proposal.target == cleanTargetPath,
              proposal.baseRevision == cleanBaseDigest,
              Self.stableLocalDigest(proposal.proposedContent) == cleanProposedDigest,
              !cleanTargetPath.isEmpty,
              !cleanBaseDigest.isEmpty,
              !cleanProposedDigest.isEmpty,
              diffSummary.utf8.count <= 16_384,
              unifiedDiff.utf8.count <= 524_288 else { return nil }
        let record = DesktopKnowledgeWriteRecord(
            id: UUID().uuidString.lowercased(),
            proposalID: proposalID,
            approvalID: nil,
            targetPath: cleanTargetPath,
            baseDigest: cleanBaseDigest,
            proposedDigest: cleanProposedDigest,
            diffSummary: diffSummary,
            unifiedDiff: unifiedDiff,
            state: .proposed,
            currentDigest: nil,
            createdAtUnixMillis: now(),
            reconciledAtUnixMillis: nil
        )
        let timestamp = now()
        let persisted = mutate { snapshot in
            snapshot.operations.knowledgeWrites.append(record)
            for laneIndex in snapshot.operations.codingKnowledgeLanes.indices
            where snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID == proposalID
                && Self.hasAcceptedCodingWorktree(
                    in: snapshot,
                    threadID: snapshot.operations.codingKnowledgeLanes[laneIndex].threadID
                ) {
                let threadID = snapshot.operations.codingKnowledgeLanes[laneIndex].threadID
                snapshot.operations.codingKnowledgeLanes[laneIndex].writeID = record.id
                snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .proposed
                snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "Knowledge write proposal is ready for review."
                snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
                Self.setCodingWorkflow(
                    in: &snapshot,
                    threadID: threadID,
                    state: .updatingKnowledge,
                    reason: "Knowledge write proposal is ready for review.",
                    timestamp: timestamp
                )
            }
        }
        return persisted ? record.id : nil
    }

    @discardableResult
    public func attachKnowledgeApproval(writeID: String, approvalID: String) -> Bool {
        guard let write = snapshot.operations.knowledgeWrites.first(where: { $0.id == writeID }),
              let approval = snapshot.operations.approvals.first(where: {
                  $0.id == approvalID && $0.state == .awaitingApproval
              }),
              approval.exactTarget == Self.knowledgeApprovalTarget(
                  path: write.targetPath,
                  baseDigest: write.baseDigest
              ) else { return false }
        if let lane = snapshot.operations.codingKnowledgeLanes.first(where: {
            $0.writeID == writeID || $0.proposalID == write.proposalID
        }), approval.threadID != lane.threadID { return false }
        var didApply = false
        let persisted = mutate { snapshot in
            guard let index = snapshot.operations.knowledgeWrites.firstIndex(where: { $0.id == writeID }),
                  let approval = snapshot.operations.approvals.first(where: {
                      $0.id == approvalID && $0.state == .awaitingApproval
                  }),
                  approval.exactTarget == Self.knowledgeApprovalTarget(
                      path: snapshot.operations.knowledgeWrites[index].targetPath,
                      baseDigest: snapshot.operations.knowledgeWrites[index].baseDigest
                  ) else { return }
            snapshot.operations.knowledgeWrites[index].approvalID = approvalID
            snapshot.operations.knowledgeWrites[index].state = .awaitingApproval
            let proposalID = snapshot.operations.knowledgeWrites[index].proposalID
            if let proposalIndex = snapshot.operations.knowledgeProposals.firstIndex(where: { $0.id == proposalID }) {
                snapshot.operations.knowledgeProposals[proposalIndex].state = .awaitingApproval
            }
            let timestamp = now()
            for laneIndex in snapshot.operations.codingKnowledgeLanes.indices
            where snapshot.operations.codingKnowledgeLanes[laneIndex].writeID == writeID
                || snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID == proposalID {
                let threadID = snapshot.operations.codingKnowledgeLanes[laneIndex].threadID
                guard Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
                      snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge else { continue }
                snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .awaitingApproval
                snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "Knowledge update is awaiting exact approval."
                snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
                Self.setCodingWorkflow(
                    in: &snapshot,
                    threadID: threadID,
                    state: .updatingKnowledge,
                    reason: "Knowledge update is awaiting exact approval.",
                    timestamp: timestamp
                )
            }
            didApply = true
        }
        return didApply && persisted
    }

    public func reconcileKnowledgeWrite(
        id: String,
        state: DesktopActionState,
        currentDigest: String?,
        detail: String
    ) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.knowledgeWrites.firstIndex(where: { $0.id == id }) else { return }
            let digestMatchesProposal = currentDigest != nil
                && currentDigest == snapshot.operations.knowledgeWrites[index].proposedDigest
            let effectiveState: DesktopActionState = state == .reconciled && !digestMatchesProposal ? .failed : state
            let effectiveDetail = state == .reconciled && !digestMatchesProposal
                ? "Reconciliation digest did not match the proposed content. \(detail)"
                : detail
            snapshot.operations.knowledgeWrites[index].state = effectiveState
            snapshot.operations.knowledgeWrites[index].currentDigest = currentDigest
            snapshot.operations.knowledgeWrites[index].reconciledAtUnixMillis = timestamp
            if let proposalIndex = snapshot.operations.knowledgeProposals.firstIndex(where: {
                $0.id == snapshot.operations.knowledgeWrites[index].proposalID
            }) { snapshot.operations.knowledgeProposals[proposalIndex].state = effectiveState }
            if let documentIndex = snapshot.operations.knowledgeDocuments.firstIndex(where: {
                $0.path == snapshot.operations.knowledgeWrites[index].targetPath
            }) { snapshot.operations.knowledgeDocuments[documentIndex].conflictDigest = effectiveState == .failed ? currentDigest : nil }
            let writeID = snapshot.operations.knowledgeWrites[index].id
            let proposalID = snapshot.operations.knowledgeWrites[index].proposalID
            let linkedLaneIndexes = snapshot.operations.codingKnowledgeLanes.indices.filter {
                snapshot.operations.codingKnowledgeLanes[$0].writeID == writeID
                    || snapshot.operations.codingKnowledgeLanes[$0].proposalID == proposalID
            }
            for laneIndex in linkedLaneIndexes {
                let threadID = snapshot.operations.codingKnowledgeLanes[laneIndex].threadID
                guard Self.hasAcceptedCodingWorktree(in: snapshot, threadID: threadID),
                      snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .updatingKnowledge else { continue }
                if effectiveState == .reconciled {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .reconciled
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = KanameTextBounds.utf8Prefix(
                        Self.normalized(effectiveDetail),
                        maximumBytes: Self.codingKnowledgeMaximumReasonBytes
                    )
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID,
                        state: .completed,
                        reason: "Knowledge update reconciled successfully.",
                        timestamp: timestamp
                    )
                    if let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
                        snapshot.threads[threadIndex].attention = .completed
                        snapshot.threads[threadIndex].summary = "Implementation accepted locally. Knowledge update reconciled; nothing was pushed or published."
                        snapshot.threads[threadIndex].unread = false
                        snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
                    }
                } else if effectiveState == .failed {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .conflict
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = KanameTextBounds.utf8Prefix(
                        Self.normalized(effectiveDetail),
                        maximumBytes: Self.codingKnowledgeMaximumReasonBytes
                    )
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID,
                        state: .updatingKnowledge,
                        reason: "Knowledge update conflicted and requires review.",
                        timestamp: timestamp
                    )
                    if let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
                        snapshot.threads[threadIndex].attention = .needsApproval
                        snapshot.threads[threadIndex].summary = "Knowledge update conflicted; review the external note and decide whether to retry or waive it."
                        snapshot.threads[threadIndex].unread = true
                        snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
                    }
                }
                snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            }
            snapshot.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(),
                domain: "knowledge",
                action: "write reconciliation",
                target: snapshot.operations.knowledgeWrites[index].targetPath,
                state: effectiveState,
                detail: effectiveDetail,
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    public func reviewCapabilityUpdate(id: String, accepted: Bool) {
        mutate { snapshot in
            snapshot.operations.capabilityUpdates = snapshot.operations.capabilityUpdates.map { update in
                guard update.id == id else { return update }
                var reviewed = update
                reviewed.state = accepted ? .approved : .rejected
                reviewed.reviewedAtUnixMillis = now()
                return reviewed
            }
        }
    }

    private static func knowledgeApprovalTarget(path: String, baseDigest: String) -> String {
        "obsidian:\(path)#sha256=\(baseDigest)"
    }
}
