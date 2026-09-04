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
    public func addProviderPlan(threadID: String, text: String, completed: Bool) {
        let clean = Self.normalized(text)
        guard !clean.isEmpty else { return }
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            let item = DesktopPlanItem(
                id: "provider-plan-\(Self.stableLocalDigest(clean).prefix(16))",
                title: String(clean.prefix(2_000)),
                state: completed ? .complete : .inProgress
            )
            if let itemIndex = snapshot.threads[index].plan.firstIndex(where: { $0.id == item.id }) {
                snapshot.threads[index].plan[itemIndex] = item
            } else {
                snapshot.threads[index].plan.append(item)
            }
        }
    }

    /// Appends findings parsed from a provider reply, skipping duplicates.
    public func appendFindings(threadID: String, runID: String?, texts: [String]) {
        let timestamp = now()
        let items = texts.compactMap { raw -> DesktopFinding? in
            let clean = Self.normalized(raw)
            guard !clean.isEmpty else { return nil }
            let firstSentence = clean.split(whereSeparator: { $0 == "\n" || $0 == "." }).first.map(String.init) ?? clean
            return DesktopFinding(
                id: "finding-\(Self.stableLocalDigest(clean).prefix(16))",
                title: String(firstSentence.prefix(140)),
                detail: String(clean.prefix(4_000)),
                runID: runID,
                createdAtUnixMillis: timestamp
            )
        }
        guard !items.isEmpty else { return }
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            var existing = snapshot.threads[index].findings ?? []
            let known = Set(existing.map(\.id))
            existing += items.filter { !known.contains($0.id) }
            snapshot.threads[index].findings = Array(existing.suffix(200))
            snapshot.threads[index].updatedAtUnixMillis = timestamp
        }
    }

    /// Records a note the provider proposed through the Kaname Bridge.
    public func addKnowledgeNoteProposal(threadID: String, runID: String?, path: String, content: String, rationale: String) {
        let timestamp = now()
        guard let thread = thread(id: threadID), thread.kind == .coding else { return }
        let proposal = DesktopKnowledgeNoteProposal(
            id: "note-proposal-\(Self.stableLocalDigest(path + "\u{0}" + content).prefix(16))",
            path: path,
            content: String(content.prefix(256 * 1_024)),
            rationale: String(rationale.prefix(4_000)),
            runID: runID,
            createdAtUnixMillis: timestamp
        )
        mutate { snapshot in
            guard let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            if let laneIndex = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }) {
                var proposals = snapshot.operations.codingKnowledgeLanes[laneIndex].noteProposals ?? []
                proposals.removeAll { $0.path == proposal.path }
                proposals.append(proposal)
                snapshot.operations.codingKnowledgeLanes[laneIndex].noteProposals = Array(proposals.suffix(20))
                snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
            } else {
                var lane = DesktopCodingKnowledgeLane(
                    projectID: snapshot.threads[threadIndex].projectID,
                    threadID: threadID,
                    createdAtUnixMillis: timestamp,
                    updatedAtUnixMillis: timestamp
                )
                lane.noteProposals = [proposal]
                snapshot.operations.codingKnowledgeLanes.append(lane)
            }
            snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
        }
    }

    /// Stores the full Markdown plan body shown above the step outline.
    public func setProviderPlanBody(threadID: String, text: String?) {
        let clean = text.map(Self.normalized) ?? ""
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].planBody = clean.isEmpty ? nil : String(clean.prefix(64 * 1_024))
            snapshot.threads[index].updatedAtUnixMillis = now()
        }
    }

    public func replaceProviderPlan(
        threadID: String,
        steps: [(title: String, status: String)],
        explanation: String?
    ) {
        let items = steps.enumerated().map { index, entry in
            let status = entry.status.lowercased().replacingOccurrences(of: "_", with: "")
            let state: DesktopPlanItem.State = switch status {
            case "completed", "complete": .complete
            case "inprogress": .inProgress
            default: .pending
            }
            return DesktopPlanItem(
                id: "provider-plan-\(index)-\(Self.stableLocalDigest(entry.title).prefix(16))",
                title: entry.title,
                state: state
            )
        }
        guard !items.isEmpty else { return }
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].plan = items
            if let explanation {
                snapshot.threads[index].summary = explanation
            }
            snapshot.threads[index].updatedAtUnixMillis = now()
        }
    }

    public func markCodingPlanUnavailable(threadID: String) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].attention = .failed
            snapshot.threads[index].summary = "The planning turn ended without a readable plan. Ask again or rephrase."
            snapshot.threads[index].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .failed,
                reason: "The planning turn completed without a readable plan.",
                timestamp: timestamp
            )
        }
    }

    public func finalizeCodingPlanForApproval(threadID: String) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            for planIndex in snapshot.threads[index].plan.indices { snapshot.threads[index].plan[planIndex].state = .pending }
            snapshot.threads[index].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: .awaitingPlanApproval,
                reason: "The plan is ready for explicit approval.",
                timestamp: timestamp
            )
        }
    }

    @discardableResult
    public func recordCodingEvidence(
        threadID: String,
        worktreeID: String,
        revision: String,
        diffStat: String,
        diffCheckPassed: Bool,
        verificationCommand: String,
        verificationExitStatus: Int32,
        verificationOutput: String,
        artifactPaths: [String],
        digest: String,
        verificationWasRun: Bool = true
    ) -> Bool {
        guard let currentThread = thread(id: threadID), currentThread.kind == .coding,
              codingWorkflow(threadID: threadID)?.state == .reviewingEvidence,
              snapshot.operations.worktrees.contains(where: {
                  $0.id == worktreeID && $0.threadID == threadID && ($0.state == .ready || $0.state == .review)
              }) else { return false }
        let changedFilesState: DesktopEvidence.State = artifactPaths.isEmpty ? .failed : .passed
        let testState: DesktopEvidence.State = !verificationWasRun ? .notRun : (verificationExitStatus == 0 ? .passed : .failed)
        let diffState: DesktopEvidence.State = diffCheckPassed ? .passed : .failed
        let evidencePassed = diffCheckPassed && (!verificationWasRun || verificationExitStatus == 0) && !artifactPaths.isEmpty
        let items = [
            DesktopEvidence(
                id: "coding-diff-\(worktreeID)",
                label: "Diff integrity",
                detail: diffStat.isEmpty ? "No changed files were found." : diffStat,
                state: diffState
            ),
            DesktopEvidence(
                id: "coding-tests-\(worktreeID)",
                label: verificationCommand,
                detail: String((verificationOutput.isEmpty ? "No command output." : verificationOutput).suffix(4_000)),
                state: testState
            ),
            DesktopEvidence(
                id: "coding-files-\(worktreeID)",
                label: "Changed files",
                detail: artifactPaths.isEmpty ? "No implementation changes were produced." : artifactPaths.joined(separator: ", "),
                state: changedFilesState
            ),
            DesktopEvidence(
                id: "coding-revision-\(worktreeID)",
                label: "Evidence digest",
                detail: digest,
                state: evidencePassed ? .passed : .failed
            ),
        ]
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            guard let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  snapshot.threads[threadIndex].kind == .coding,
                  snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state == .reviewingEvidence,
                  let worktreeIndex = snapshot.operations.worktrees.firstIndex(where: {
                      $0.id == worktreeID && $0.threadID == threadID && ($0.state == .ready || $0.state == .review)
                  }) else { return }
            snapshot.threads[threadIndex].evidence = items
            snapshot.threads[threadIndex].attention = .needsApproval
            snapshot.threads[threadIndex].summary = evidencePassed
                ? "Evidence is ready. Review and accept or reject the implementation."
                : "Evidence found a failure. Review it before deciding what to do."
            if evidencePassed {
                for index in snapshot.threads[threadIndex].plan.indices {
                    snapshot.threads[threadIndex].plan[index].state = .complete
                }
            }
            snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
            snapshot.operations.worktrees[worktreeIndex].headRevision = revision
            snapshot.operations.worktrees[worktreeIndex].changedFileCount = artifactPaths.count
            snapshot.operations.worktrees[worktreeIndex].diffSummary = String(diffStat.prefix(32_000))
            snapshot.operations.worktrees[worktreeIndex].testCommand = verificationCommand
            snapshot.operations.worktrees[worktreeIndex].testSummary = String(verificationOutput.suffix(32_000))
            snapshot.operations.worktrees[worktreeIndex].diagnosticSummary = "Evidence digest \(digest)"
            snapshot.operations.worktrees[worktreeIndex].state = .review
            snapshot.operations.worktrees[worktreeIndex].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: evidencePassed ? .awaitingAcceptance : .reviewingEvidence,
                reason: evidencePassed
                    ? "Independent evidence passed; accept or reject the implementation."
                    : "Independent evidence contains a failure and requires review.",
                timestamp: timestamp
            )
            didApply = true
        }
        return didApply && persisted
    }

    @discardableResult
    public func recordCodingReview(threadID: String, worktreeID: String, accepted: Bool) -> Bool {
        let currentWorkflowState = codingWorkflow(threadID: threadID)?.state
        let reviewStateIsValid = accepted
            ? currentWorkflowState == .awaitingAcceptance
            : currentWorkflowState == .awaitingAcceptance || currentWorkflowState == .reviewingEvidence
        guard let currentThread = thread(id: threadID), currentThread.kind == .coding,
              reviewStateIsValid,
              snapshot.operations.worktrees.contains(where: {
                  $0.id == worktreeID && $0.threadID == threadID && $0.state == .review
              }) else { return false }
        if accepted {
            guard !currentThread.evidence.isEmpty,
                  currentThread.evidence.allSatisfy({ $0.state == .passed || $0.state == .notRun }) else { return false }
        }
        let timestamp = now()
        var didApply = false
        let persisted = mutate { snapshot in
            let persistedWorkflowState = snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state
            let persistedReviewStateIsValid = accepted
                ? persistedWorkflowState == .awaitingAcceptance
                : persistedWorkflowState == .awaitingAcceptance || persistedWorkflowState == .reviewingEvidence
            guard let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  snapshot.threads[threadIndex].kind == .coding,
                  persistedReviewStateIsValid,
                  let worktreeIndex = snapshot.operations.worktrees.firstIndex(where: {
                      $0.id == worktreeID && $0.threadID == threadID && $0.state == .review
                  }) else { return }
            if accepted {
                guard !snapshot.threads[threadIndex].evidence.isEmpty,
                      snapshot.threads[threadIndex].evidence.allSatisfy({ $0.state == .passed || $0.state == .notRun }) else { return }
            }
            snapshot.operations.worktrees[worktreeIndex].state = accepted ? .accepted : .dirty
            snapshot.operations.worktrees[worktreeIndex].updatedAtUnixMillis = timestamp
            snapshot.threads[threadIndex].attention = accepted ? .needsApproval : .needsResponse
            snapshot.threads[threadIndex].summary = accepted
                ? "Accepted. Drafting the knowledge update; nothing was pushed."
                : "Implementation rejected. The isolated changes remain available for revision."
            snapshot.threads[threadIndex].unread = false
            snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
            Self.setCodingWorkflow(
                in: &snapshot,
                threadID: threadID,
                state: accepted ? .updatingKnowledge : .rejected,
                reason: accepted
                    ? "Implementation accepted locally; review, reconcile, or waive the knowledge lane."
                    : "The implementation was rejected and remains available for revision.",
                timestamp: timestamp
            )
            if accepted {
                if let laneIndex = snapshot.operations.codingKnowledgeLanes.firstIndex(where: { $0.threadID == threadID }) {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].acceptedWorktreeID = worktreeID
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .needsReview
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "Implementation was accepted locally; knowledge disposition is pending review."
                    snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = timestamp
                } else {
                    snapshot.operations.codingKnowledgeLanes.append(.init(
                        projectID: snapshot.threads[threadIndex].projectID,
                        threadID: threadID,
                        disposition: .needsReview,
                        dispositionReason: "Implementation was accepted locally; knowledge disposition is pending review.",
                        acceptedWorktreeID: worktreeID,
                        createdAtUnixMillis: timestamp,
                        updatedAtUnixMillis: timestamp
                    ))
                }
            }
            didApply = true
        }
        return didApply && persisted
    }

    @discardableResult
    public func createProviderComparison(title: String, brief: String, providers: [String]) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBrief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let uniqueProviders = Array(Set(providers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
            .sorted()
        guard !cleanTitle.isEmpty, !cleanBrief.isEmpty, uniqueProviders.count >= 2 else { return nil }
        let timestamp = now()
        let runs = uniqueProviders.map { provider in
            DesktopProviderRunRecord(
                id: UUID().uuidString.lowercased(),
                threadID: nil,
                turnID: UUID().uuidString.lowercased(),
                provider: provider,
                model: "Not selected",
                briefDigest: Self.stableLocalDigest(cleanBrief),
                contextReferenceCount: 0,
                tokenUsage: nil,
                costSummary: "Not run",
                state: .proposed,
                startedAtUnixMillis: timestamp,
                completedAtUnixMillis: nil
            )
        }
        let comparison = DesktopComparisonRecord(
            id: UUID().uuidString.lowercased(),
            title: cleanTitle,
            brief: cleanBrief,
            runIDs: runs.map(\.id),
            state: .proposed,
            createdAtUnixMillis: timestamp
        )
        let decision = DesktopComparisonDecisionRecord(
            id: "decision-\(comparison.id)",
            comparisonID: comparison.id,
            frozenContextDigest: Self.stableLocalDigest(cleanBrief),
            selectedRunID: nil,
            continuedThreadID: nil,
            decidedAtUnixMillis: nil
        )
        mutate { snapshot in
            snapshot.operations.providerRuns.append(contentsOf: runs)
            snapshot.operations.comparisons.append(comparison)
            snapshot.operations.comparisonDecisions.append(decision)
        }
        return comparison.id
    }

    public func prepareProviderComparison(id: String, projectID: String?) -> [String] {
        guard let comparisonIndex = snapshot.operations.comparisons.firstIndex(where: {
            $0.id == id && $0.state == .proposed
        }) else { return [] }
        let comparison = snapshot.operations.comparisons[comparisonIndex]
        let timestamp = now()
        var preparedRunIDs: [String] = []
        mutate { snapshot in
            for runID in comparison.runIDs {
                guard let runIndex = snapshot.operations.providerRuns.firstIndex(where: {
                    $0.id == runID && $0.threadID == nil
                }) else { continue }
                let provider = snapshot.operations.providerRuns[runIndex].provider
                let turnID = snapshot.operations.providerRuns[runIndex].turnID
                let threadID = UUID().uuidString.lowercased()
                let messageID = turnID
                let thread = DesktopThread(
                    id: threadID,
                    projectID: projectID,
                    title: "\(comparison.title) · \(provider)",
                    summary: "Frozen equal-context comparison run",
                    kind: .coding,
                    attention: .queued,
                    provider: provider,
                    model: "Use provider default",
                    updatedAtUnixMillis: timestamp,
                    messages: [DesktopMessage(
                        id: messageID,
                        turnID: turnID,
                        role: .user,
                        body: comparison.brief,
                        createdAtUnixMillis: timestamp
                    )]
                )
                snapshot.threads.append(thread)
                snapshot.operations.providerRuns[runIndex].threadID = threadID
                snapshot.operations.providerRuns[runIndex].sourceMessageID = messageID
                snapshot.operations.providerRuns[runIndex].model = "Use provider default"
                snapshot.operations.providerRuns[runIndex].costSummary = "Queued from frozen context"
                preparedRunIDs.append(runID)
            }
            snapshot.operations.comparisons[comparisonIndex].state = preparedRunIDs.isEmpty ? .failed : .running
        }
        return preparedRunIDs
    }

    public func selectProviderComparisonResult(comparisonID: String, runID: String) -> String? {
        guard let comparison = snapshot.operations.comparisons.first(where: { $0.id == comparisonID }),
              comparison.runIDs.contains(runID),
              let run = snapshot.operations.providerRuns.first(where: { $0.id == runID && $0.state == .completed }),
              let threadID = run.threadID else { return nil }
        let timestamp = now()
        mutate { snapshot in
            if let index = snapshot.operations.comparisons.firstIndex(where: { $0.id == comparisonID }) {
                snapshot.operations.comparisons[index].state = .completed
            }
            if let index = snapshot.operations.comparisonDecisions.firstIndex(where: { $0.comparisonID == comparisonID }) {
                snapshot.operations.comparisonDecisions[index].selectedRunID = runID
                snapshot.operations.comparisonDecisions[index].continuedThreadID = threadID
                snapshot.operations.comparisonDecisions[index].decidedAtUnixMillis = timestamp
            }
        }
        return threadID
    }

    @discardableResult
    public func proposeWorktree(
        projectID: String,
        threadID: String,
        rootWorkspacePath: String,
        worktreePath: String,
        branch: String,
        baseRevision: String
    ) -> String? {
        let root = Self.normalized(rootWorkspacePath)
        let target = Self.normalized(worktreePath)
        let cleanBranch = Self.normalized(branch)
        let cleanBase = Self.normalized(baseRevision)
        guard snapshot.projects.contains(where: { $0.id == projectID }),
              snapshot.threads.contains(where: { $0.id == threadID && $0.projectID == projectID }),
              !root.isEmpty, !target.isEmpty, !cleanBranch.isEmpty, !cleanBase.isEmpty else { return nil }
        let timestamp = now()
        let record = DesktopWorktreeRecord(
            id: UUID().uuidString.lowercased(),
            projectID: projectID,
            threadID: threadID,
            rootWorkspacePath: root,
            worktreePath: target,
            branch: cleanBranch,
            baseRevision: cleanBase,
            headRevision: nil,
            changedFileCount: 0,
            diffSummary: "Not created",
            testCommand: "",
            testSummary: "Not run",
            diagnosticSummary: "Not inspected",
            state: .proposed,
            createdAtUnixMillis: timestamp,
            updatedAtUnixMillis: timestamp
        )
        mutate { $0.operations.worktrees.append(record) }
        return record.id
    }

    public func updateWorktree(
        id: String,
        headRevision: String?,
        changedFileCount: Int,
        diffSummary: String,
        testCommand: String? = nil,
        testSummary: String? = nil,
        diagnosticSummary: String? = nil,
        state: DesktopWorktreeState
    ) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.worktrees.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.worktrees[index].headRevision = headRevision
            snapshot.operations.worktrees[index].changedFileCount = max(0, changedFileCount)
            snapshot.operations.worktrees[index].diffSummary = String(diffSummary.prefix(32_000))
            if let testCommand { snapshot.operations.worktrees[index].testCommand = String(testCommand.prefix(4_096)) }
            if let testSummary { snapshot.operations.worktrees[index].testSummary = String(testSummary.prefix(32_000)) }
            if let diagnosticSummary { snapshot.operations.worktrees[index].diagnosticSummary = String(diagnosticSummary.prefix(32_000)) }
            snapshot.operations.worktrees[index].state = state
            snapshot.operations.worktrees[index].updatedAtUnixMillis = timestamp
        }
    }

    public func upsertCodingTerminal(_ record: DesktopCodingTerminalRecord) {
        mutate { snapshot in
            Self.replaceOrAppend(
                record,
                in: &snapshot.operations.codingTerminals
            ) { $0.id == record.id && $0.threadID == record.threadID }
        }
    }

    public func upsertCodingCheckpoint(_ record: DesktopCodingCheckpointRecord) {
        mutate { snapshot in
            Self.replaceOrAppend(record, in: &snapshot.operations.codingCheckpoints) { $0.id == record.id }
        }
    }

    public func upsertCodingPreviewTab(_ record: DesktopCodingPreviewTabRecord) {
        mutate { snapshot in
            Self.replaceOrAppend(record, in: &snapshot.operations.codingPreviewTabs) { $0.id == record.id }
        }
    }

    private static func replaceOrAppend<Element>(
        _ element: Element,
        in elements: inout [Element],
        matching: (Element) -> Bool
    ) {
        if let index = elements.firstIndex(where: matching) {
            elements[index] = element
        } else {
            elements.append(element)
        }
    }

    @discardableResult
    public func recordQualityGate(
        threadID: String,
        worktreeID: String?,
        kind: DesktopQualityGateKind,
        command: String,
        summary: String,
        state: DesktopActionState,
        artifactIDs: [String] = []
    ) -> String? {
        guard snapshot.threads.contains(where: { $0.id == threadID }),
              worktreeID == nil || snapshot.operations.worktrees.contains(where: { $0.id == worktreeID }) else { return nil }
        let record = DesktopQualityGateRecord(
            id: UUID().uuidString.lowercased(),
            threadID: threadID,
            worktreeID: worktreeID,
            kind: kind,
            command: String(Self.normalized(command).prefix(4_096)),
            summary: String(Self.normalized(summary).prefix(32_000)),
            state: state,
            artifactIDs: artifactIDs,
            recordedAtUnixMillis: now()
        )
        mutate { snapshot in
            snapshot.operations.qualityGates.removeAll {
                $0.threadID == threadID && $0.worktreeID == worktreeID && $0.kind == kind
            }
            snapshot.operations.qualityGates.append(record)
        }
        return record.id
    }

    public func recordSubagentActivity(
        threadID: String,
        runID: String,
        provider: String,
        nativeID: String,
        parentNativeID: String? = nil,
        title: String,
        detail: String,
        state: DesktopSubagentState
    ) {
        let id = "subagent-\(Self.stableLocalDigest("\(runID)|\(nativeID)"))"
        let parentID = parentNativeID.map {
            "subagent-\(Self.stableLocalDigest("\(runID)|\($0)"))"
        }
        let timestamp = now()
        mutate { snapshot in
            if let index = snapshot.operations.subagents.firstIndex(where: { $0.id == id }) {
                snapshot.operations.subagents[index].parentID = parentID
                snapshot.operations.subagents[index].title = String(Self.normalized(title).prefix(240))
                snapshot.operations.subagents[index].detail = String(detail.prefix(8_192))
                snapshot.operations.subagents[index].state = state
                snapshot.operations.subagents[index].completedAtUnixMillis = [.completed, .failed, .interrupted].contains(state) ? timestamp : nil
            } else {
                snapshot.operations.subagents.append(DesktopSubagentRecord(
                    id: id,
                    threadID: threadID,
                    runID: runID,
                    parentID: parentID,
                    provider: provider,
                    title: String(Self.normalized(title).prefix(240)),
                    detail: String(detail.prefix(8_192)),
                    state: state,
                    startedAtUnixMillis: timestamp,
                    completedAtUnixMillis: [.completed, .failed, .interrupted].contains(state) ? timestamp : nil
                ))
            }
        }
    }

    public func replacePullRequests(workspaceID: String, records: [DesktopPullRequestReconciliation]) {
        mutate { snapshot in
            snapshot.operations.pullRequests.removeAll { $0.workspaceID == workspaceID }
            snapshot.operations.pullRequests.append(contentsOf: records.map { record in
                DesktopPullRequestRecord(
                    id: "\(record.repository)#\(record.number)",
                    workspaceID: workspaceID,
                    repository: record.repository,
                    number: record.number,
                    title: record.title,
                    url: record.url,
                    headBranch: record.headBranch,
                    baseBranch: record.baseBranch,
                    checkSummary: record.checkSummary,
                    reviewSummary: record.reviewSummary,
                    mergeAfterIDs: record.mergeAfterIDs,
                    state: record.state,
                    lastReconciledAtUnixMillis: record.reconciledAtUnixMillis
                )
            })
        }
    }

    @discardableResult
    public func addGitStackLayer(
        workspaceID: String,
        title: String,
        branch: String,
        baseBranch: String,
        dependsOnLayerID: String?
    ) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBase = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.domains.gitWorkspaces.contains(where: { $0.id == workspaceID }),
              !cleanTitle.isEmpty, !cleanBranch.isEmpty, !cleanBase.isEmpty else { return nil }
        if let dependsOnLayerID,
           !snapshot.operations.gitStackLayers.contains(where: { $0.id == dependsOnLayerID }) {
            return nil
        }
        let layer = DesktopGitStackLayer(
            id: UUID().uuidString.lowercased(),
            workspaceID: workspaceID,
            title: cleanTitle,
            branch: cleanBranch,
            baseBranch: cleanBase,
            pullRequestURL: nil,
            checkSummary: "Not checked",
            reviewSummary: "No remote review",
            state: .proposed,
            dependsOnLayerID: dependsOnLayerID
        )
        mutate { $0.operations.gitStackLayers.append(layer) }
        return layer.id
    }

    public func updateGitStackLayer(
        id: String,
        pullRequestURL: String?,
        checkSummary: String,
        reviewSummary: String,
        state: DesktopActionState
    ) {
        mutate { snapshot in
            guard let index = snapshot.operations.gitStackLayers.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.gitStackLayers[index].pullRequestURL = pullRequestURL
            snapshot.operations.gitStackLayers[index].checkSummary = String(checkSummary.prefix(4_096))
            snapshot.operations.gitStackLayers[index].reviewSummary = String(reviewSummary.prefix(4_096))
            snapshot.operations.gitStackLayers[index].state = state
        }
    }

    @discardableResult
    public func registerArtifact(
        threadID: String?,
        name: String,
        kind: DesktopArtifactRecord.Kind,
        localPath: String,
        digest: String,
        provenance: String
    ) -> String? {
        let identity = (name: Self.normalized(name), path: Self.normalized(localPath))
        guard !identity.name.isEmpty, !identity.path.isEmpty else { return nil }
        switch threadID {
        case .some(let value) where !snapshot.threads.contains(where: { $0.id == value }):
            return nil
        default:
            break
        }
        let artifact = DesktopArtifactRecord(
            id: UUID().uuidString.lowercased(),
            threadID: threadID,
            name: identity.name,
            kind: kind,
            localPath: identity.path,
            digest: Self.normalized(digest),
            provenance: Self.normalized(provenance),
            createdAtUnixMillis: now()
        )
        mutate { $0.operations.artifacts.append(artifact) }
        return artifact.id
    }

    static func ensureCodingWorkflow(
        in snapshot: inout DesktopAppSnapshot,
        threadID: String,
        projectID: String?,
        timestamp: Int64
    ) {
        guard let thread = snapshot.threads.first(where: { $0.id == threadID }), thread.kind == .coding,
              !snapshot.operations.codingWorkflows.contains(where: { $0.threadID == threadID }) else { return }
        snapshot.operations.codingWorkflows.append(DesktopCodingWorkflowRecord(
            projectID: projectID ?? thread.projectID,
            threadID: threadID,
            createdAtUnixMillis: timestamp,
            updatedAtUnixMillis: timestamp
        ))
    }

    static func hasAcceptedCodingWorktree(
        in snapshot: DesktopAppSnapshot,
        threadID: String
    ) -> Bool {
        guard let acceptedWorktreeID = snapshot.operations.codingKnowledgeLanes.first(where: {
            $0.threadID == threadID
        })?.acceptedWorktreeID else { return false }
        return snapshot.operations.worktrees.contains {
            $0.id == acceptedWorktreeID && $0.threadID == threadID && $0.state == .accepted
        }
    }

    static func setCodingWorkflow(
        in snapshot: inout DesktopAppSnapshot,
        threadID: String,
        projectID: String? = nil,
        state: DesktopCodingWorkflowState,
        reason: String? = nil,
        timestamp: Int64
    ) {
        guard let thread = snapshot.threads.first(where: { $0.id == threadID }), thread.kind == .coding else { return }
        ensureCodingWorkflow(in: &snapshot, threadID: threadID, projectID: projectID ?? thread.projectID, timestamp: timestamp)
        guard let index = snapshot.operations.codingWorkflows.firstIndex(where: { $0.threadID == threadID }) else { return }
        snapshot.operations.codingWorkflows[index].state = state
        if let reason {
            let cleanReason = normalized(reason)
            snapshot.operations.codingWorkflows[index].reason = cleanReason.isEmpty
                ? nil
                : KanameTextBounds.utf8Prefix(cleanReason, maximumBytes: codingKnowledgeMaximumReasonBytes)
        } else {
            snapshot.operations.codingWorkflows[index].reason = nil
        }
        snapshot.operations.codingWorkflows[index].updatedAtUnixMillis = timestamp
    }
}
