import KanameDesktop
import KanameDesktopUI
import KanameDesignSystem
import KanameWorkflowHost
import KanameConnectivity
import KanameDomain
import KanamePrototypeUI
import KanameLocalCore
import KanameLinkHost
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct WorkflowWorkItemCard: View {
    @ObservedObject var model: DesktopAppModel
    let item: DesktopWorkflowWorkItemRecord
    let expanded: Bool
    let requestEffectApproval: (DesktopWorkflowEffectRecord) -> Void
    let executeEffect: (DesktopWorkflowEffectRecord) -> Void
    let completeHumanReview: (String, String) -> Void
    let toggleExpanded: () -> Void
    @State private var standingGrantPreview: DesktopWorkflowEffectPreviewRecord? = nil

    private var definition: DesktopWorkflowDefinitionRecord? {
        model.snapshot.operations.workflows.definitions.first { $0.id == item.workflowID }
    }

    private var statusPresentation: KanameStatusPresentation {
        KanameDesktopStatusPresentation.workflow(item.state)
    }

    private var episodes: [DesktopWorkflowEpisodeRecord] {
        model.workflowEpisodes(workItemID: item.id)
    }

    private var currentEpisode: DesktopWorkflowEpisodeRecord? {
        item.currentEpisodeID.flatMap { id in episodes.first { $0.id == id } }
    }

    private var runs: [DesktopWorkflowRunRecord] {
        model.snapshot.operations.workflows.runs.filter { $0.workItemID == item.id }
            .sorted { ($0.startedAtUnixMillis ?? 0, $0.id) < ($1.startedAtUnixMillis ?? 0, $1.id) }
    }

    private var activeFacts: [DesktopWorkflowFactRecord] {
        let itemFacts = model.workflowFacts(workItemID: item.id).filter { $0.state == .verified }
        let accountIDs = Set(model.snapshot.operations.workflows.conversationBindings.filter {
            $0.workItemID == item.id && $0.relationship != .detached
        }.map(\.accountID))
        let installationFacts = model.workflowKnowledge(workflowID: item.workflowID).filter {
            $0.state == .verified && ($0.scope == .installation
                || ($0.scope == .accountBinding && $0.scopeID.map(accountIDs.contains) == true))
        }
        return Array(Dictionary(uniqueKeysWithValues: (itemFacts + installationFacts).map { ($0.id, $0) }).values)
            .sorted { ($0.key, $0.createdAtUnixMillis, $0.id) < ($1.key, $1.createdAtUnixMillis, $1.id) }
    }

    private var proposedKnowledge: [DesktopWorkflowFactRecord] {
        model.workflowFacts(workItemID: item.id).filter { $0.state == .proposed }
    }

    private var inactiveFacts: [DesktopWorkflowFactRecord] {
        model.workflowFacts(workItemID: item.id, includeInactive: true).filter {
            $0.state == .rejected || $0.state == .superseded || $0.state == .expired
        }
    }

    private var artifactRoles: [DesktopWorkflowArtifactRoleRecord] {
        model.workflowArtifactRoles(workItemID: item.id, includeInactive: true)
    }

    private var artifactRoleNames: [String] {
        Array(Set(artifactRoles.map(\.role))).sorted()
    }

    private var stateRecords: [DesktopWorkflowStateRecord] {
        model.workflowStateRecords(workflowID: item.workflowID)
    }

    private var pendingEffects: [DesktopWorkflowEffectRecord] {
        model.snapshot.operations.workflows.effects.filter {
            $0.workItemID == item.id && ![.reconciled, .cancelled].contains($0.state)
        }
    }

    private var pendingStructuredReviews: [DesktopWorkflowReviewRequestRecord] {
        model.pendingWorkflowReviews.filter { $0.workItemID == item.id }
    }

    private var activeWaits: [DesktopWorkflowWaitSubscriptionRecord] {
        model.activeWorkflowWaits.filter { $0.workItemID == item.id }
    }

    private var authorityGrants: [DesktopWorkflowAuthorityGrantRecord] {
        model.snapshot.operations.workflows.authorityGrants.filter { $0.workflowID == item.workflowID }
            .sorted { ($0.state.rawValue, $0.effectKind, $0.id) < ($1.state.rawValue, $1.effectKind, $1.id) }
    }

    private var datasetDefinitions: [DesktopWorkflowDatasetDefinition] {
        guard let revisionID = definition?.currentRevisionID else { return [] }
        return model.snapshot.operations.workflows.revisions.first { $0.id == revisionID }?.datasetDefinitions ?? []
    }

    private var executionReceipts: [DesktopWorkflowExecutionReceiptRecord] {
        let runIDs = Set(model.snapshot.operations.workflows.runs.filter { $0.workItemID == item.id }.map(\.id))
        return model.snapshot.operations.workflows.executionReceipts.filter { runIDs.contains($0.runID) }
            .sorted { ($0.createdAtUnixMillis, $0.id) > ($1.createdAtUnixMillis, $1.id) }
    }

    private var waitingHumanReviews: [(runID: String, step: DesktopWorkflowStepDefinition)] {
        model.snapshot.operations.workflows.runs.compactMap { run in
            guard run.workItemID == item.id, run.state == .waiting,
                  let revision = model.snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
                  let step = revision.steps.first(where: { $0.id == run.currentStepID && $0.kind == .humanReview }),
                  !pendingStructuredReviews.contains(where: { $0.runID == run.id && $0.stepID == step.id }) else {
                return nil
            }
            return (run.id, step)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggleExpanded) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: definition?.icon ?? "point.3.connected.trianglepath.dotted")
                        .font(.title3)
                        .foregroundStyle(statusPresentation.tone.color)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text(definition?.name ?? item.workflowID)
                            .font(.caption).foregroundStyle(KanameColor.accent)
                        Text(item.nextAction).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 6) {
                        KanameStatusBadge(
                            statusPresentation,
                            density: .compact
                        )
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title), \(statusPresentation.accessibilityLabel)")
            .accessibilityHint(expanded ? "Collapse workflow details" : "Show workflow details")

            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Goal", value: item.goal)
                    if let currentEpisode {
                        LabeledContent("Current episode", value: "\(currentEpisode.ordinal) · \(currentEpisode.intent.label)")
                        Text(currentEpisode.deltaSummary.isEmpty ? currentEpisode.summary : currentEpisode.deltaSummary)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    WorkflowMetricsRow(metrics: [
                        WorkflowMetricValue(label: "Episodes", value: "\(episodes.count)", tint: KanameColor.accent),
                        WorkflowMetricValue(label: "Verified", value: "\(activeFacts.count)", tint: KanameColor.success),
                        WorkflowMetricValue(
                            label: proposedKnowledge.isEmpty ? "Artifacts" : "To review",
                            value: "\(proposedKnowledge.isEmpty ? artifactRoles.count : proposedKnowledge.count)",
                            tint: proposedKnowledge.isEmpty ? KanameColor.accent : KanameColor.warning
                        )
                    ])
                    if !episodes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Episode history").font(.subheadline.weight(.semibold))
                            ForEach(episodes.suffix(12)) { episode in
                                WorkflowEpisodeRow(model: model, episode: episode)
                            }
                        }
                    }
                    if !runs.isEmpty {
                        DisclosureGroup("Run graph and history · \(runs.count)") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(runs.suffix(8)) { run in
                                    WorkflowRunGraphProjectionView(model: model, run: run)
                                }
                                if runs.count >= 2 {
                                    WorkflowRunComparisonView(
                                        comparisons: model.compareWorkflowRuns(
                                            leftRunID: runs[runs.count - 2].id,
                                            rightRunID: runs[runs.count - 1].id
                                        )
                                    )
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !activeFacts.isEmpty {
                        DisclosureGroup("Current truth") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(activeFacts) { fact in
                                    LabeledContent {
                                        Text(fact.value).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    } label: {
                                        Label(fact.key, systemImage: fact.state == .verified ? "checkmark.seal.fill" : "questionmark.circle")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(fact.state == .verified ? KanameColor.success : KanameColor.warning)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !proposedKnowledge.isEmpty {
                        WorkflowKnowledgeReviewSection(facts: proposedKnowledge) { id, accepted in
                            _ = model.reviewWorkflowKnowledge(
                                id: id, accepted: accepted, reviewer: "Kaname user"
                            )
                        }
                    }
                    if !pendingStructuredReviews.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Decisions").font(.subheadline.weight(.semibold))
                            ForEach(pendingStructuredReviews) { request in
                                WorkflowStructuredReviewRow(request: request) { actionID, value in
                                    model.resolveWorkflowReview(
                                        id: request.id, actionID: actionID, value: value, reviewer: "Kaname user"
                                    )
                                }
                            }
                        }
                    }
                    if !artifactRoles.isEmpty {
                        DisclosureGroup("Artifacts · \(artifactRoles.count)") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(artifactRoleNames, id: \.self) { role in
                                    Text(role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    ForEach(artifactRoles.filter { $0.role == role }.sorted {
                                        ($0.active ? 0 : 1, -$0.createdAtUnixMillis, $0.id)
                                            < ($1.active ? 0 : 1, -$1.createdAtUnixMillis, $1.id)
                                    }) { artifact in
                                        WorkflowArtifactRoleRow(
                                            artifact: artifact,
                                            byteCount: artifactByteCount(artifact),
                                            validationSummary: artifactValidationSummary(artifact),
                                            preview: { previewArtifacts([artifact]) },
                                            exportCopy: { exportArtifact(artifact) },
                                            compareWithCurrent: artifact.active ? nil : {
                                                let current = artifactRoles.first { $0.role == artifact.role && $0.active }
                                                previewArtifacts([artifact, current].compactMap { $0 })
                                            },
                                            makeCurrent: artifact.active ? nil : {
                                                _ = model.setWorkflowArtifactRoleCurrent(id: artifact.id)
                                            },
                                            promote: {
                                                _ = model.promoteWorkflowContent(
                                                    workflowID: item.workflowID,
                                                    artifactDigest: artifact.artifactDigest,
                                                    reason: "Explicitly promoted from workflow artifact role \(artifact.role)."
                                                )
                                            }
                                        )
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !artifactRoles.isEmpty {
                        let usage = (try? model.workflowStorage(workflowID: item.workflowID)?.artifactUsageBytes()) ?? 0
                        let receipts = model.snapshot.operations.workflows.purgeReceipts.filter { $0.workflowID == item.workflowID }
                        HStack {
                            Text("Private content: \(ByteCountFormatter.string(fromByteCount: Int64(usage), countStyle: .file)) · \(receipts.count) purge receipt\(receipts.count == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("Preview purge…", action: reviewPurge)
                                .disabled(!item.state.isHistorical)
                                .help(item.state.isHistorical ? "Review eligible bytes and retained reasons" : "Content remains protected until work settles")
                        }
                    }
                    if !stateRecords.isEmpty {
                        DisclosureGroup("Operational state · \(stateRecords.count)") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(stateRecords) { record in
                                    WorkflowStateRecordRow(record: record)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !datasetDefinitions.isEmpty {
                        DisclosureGroup("Datasets · \(datasetDefinitions.count)") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(datasetDefinitions) { dataset in
                                    let count = model.snapshot.operations.workflows.datasetRows.filter {
                                        $0.workflowID == item.workflowID && $0.datasetID == dataset.id
                                    }.count
                                    WorkflowDatasetSummaryRow(definition: dataset, rowCount: count)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !executionReceipts.isEmpty {
                        DisclosureGroup("Execution evidence · \(executionReceipts.count)") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(executionReceipts) { receipt in
                                    VStack(alignment: .leading, spacing: 4) {
                                        LabeledContent {
                                            Text("\(receipt.elapsedMilliseconds) ms")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        } label: {
                                            Label(receipt.capabilityID, systemImage: "doc.text.magnifyingglass")
                                                .font(.caption.weight(.semibold))
                                        }
                                        Text("Input \(receipt.inputDigest.prefix(12)) · Output \(receipt.outputDigest?.prefix(12) ?? "none")")
                                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        if !receipt.standardOutput.isEmpty || !receipt.standardError.isEmpty {
                                            DisclosureGroup("Privacy-filtered logs") {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    if !receipt.standardOutput.isEmpty {
                                                        Text(receipt.standardOutput).textSelection(.enabled)
                                                    }
                                                    if !receipt.standardError.isEmpty {
                                                        Text(receipt.standardError).foregroundStyle(KanameColor.warning).textSelection(.enabled)
                                                    }
                                                }
                                                .font(.caption2.monospaced()).padding(.top, 4)
                                            }
                                            .font(.caption2)
                                        }
                                    }
                                    .padding(9)
                                    .background(KanameColor.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !activeWaits.isEmpty {
                        DisclosureGroup("Waiting subscriptions · \(activeWaits.count)") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(activeWaits) { WorkflowWaitRow(wait: $0) }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !authorityGrants.isEmpty {
                        DisclosureGroup("Standing authority · \(authorityGrants.count)") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(authorityGrants) { grant in
                                    WorkflowAuthorityGrantRow(
                                        grant: grant,
                                        events: model.snapshot.operations.workflows.authorityEvents.filter { $0.grantID == grant.id }
                                            .sorted { $0.recordedAtUnixMillis < $1.recordedAtUnixMillis }
                                    ) { requestedState in
                                        _ = model.setWorkflowAuthorityGrantState(id: grant.id, state: requestedState)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !inactiveFacts.isEmpty {
                        DisclosureGroup("Superseded or rejected facts") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(inactiveFacts) { fact in
                                    LabeledContent(fact.key, value: fact.value)
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !pendingEffects.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("External effects").font(.subheadline.weight(.semibold))
                            ForEach(pendingEffects) { effect in
                                let preview = model.snapshot.operations.workflows.effectPreviews.first { $0.effectID == effect.id }
                                let approval = effect.approvalID.flatMap { id in
                                    model.snapshot.operations.approvals.first { $0.id == id }
                                }
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: effect.kind == "gmail-send" ? "paperplane.fill" : "bolt.horizontal.circle")
                                        .foregroundStyle(KanameColor.warning)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(preview?.title ?? effect.kind)
                                            .font(.caption.weight(.semibold))
                                        if let summary = preview?.summary {
                                            Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Text(effect.exactTarget).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(2).textSelection(.enabled)
                                        if let preview {
                                            Text("\(preview.itemCount) item\(preview.itemCount == 1 ? "" : "s") · \(preview.reversible ? "reversible" : "not reversible")")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if effect.approvalID == nil && preview?.authorityGrantID == nil {
                                        VStack(alignment: .trailing, spacing: 5) {
                                            Button("Request approval") { requestEffectApproval(effect) }
                                            if let preview {
                                                Button("Standing grant…") { standingGrantPreview = preview }
                                                    .font(.caption)
                                            }
                                        }
                                    } else if effect.state == .outcomeUnknown {
                                        if preview != nil {
                                            Button("Reconcile result") { executeEffect(effect) }
                                                .buttonStyle(.borderedProminent)
                                                .help("Re-read every frozen target without repeating the action")
                                        } else {
                                            Text("Outcome unknown").font(.caption).foregroundStyle(KanameColor.danger)
                                        }
                                    } else if effect.state == .executing {
                                        ProgressView().controlSize(.small).accessibilityLabel("Applying email effect")
                                    } else if approval?.state == .approved || preview?.authorityGrantID != nil {
                                        Button(effect.kind == "gmail-send" ? "Send" : "Apply exact action") { executeEffect(effect) }
                                            .buttonStyle(.borderedProminent)
                                    } else {
                                        Text("Waiting in Inbox").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(10)
                                .background(KanameColor.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    ForEach(waitingHumanReviews, id: \.runID) { review in
                        WorkflowHumanReviewRow(
                            runID: review.runID,
                            stepID: review.step.id,
                            stepName: review.step.name,
                            onContinue: completeHumanReview
                        )
                    }
                    if !item.state.isHistorical {
                        HStack {
                            Spacer()
                            Button("Close operationally") { _ = model.closeWorkflowWorkItem(id: item.id, accepted: false) }
                            Button("Record acceptance") { _ = model.closeWorkflowWorkItem(id: item.id, accepted: true) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
        .panelStyle()
        .sheet(item: $standingGrantPreview) { preview in
            WorkflowStandingGrantBuilderSheet(model: model, preview: preview)
        }
    }

    private func artifactURL(_ artifact: DesktopWorkflowArtifactRoleRecord) -> URL? {
        try? model.workflowStorage(workflowID: item.workflowID)?.artifactPresentationURL(
            sha256: artifact.artifactDigest, filename: artifact.filename
        )
    }

    private func artifactByteCount(_ artifact: DesktopWorkflowArtifactRoleRecord) -> Int? {
        try? model.workflowStorage(workflowID: item.workflowID)?.artifactRecords()
            .first { $0.sha256 == artifact.artifactDigest }?.byteCount
    }

    private func artifactValidationSummary(_ artifact: DesktopWorkflowArtifactRoleRecord) -> String {
        let reportValidationIDs = Set(model.snapshot.operations.workflows.validatorReports.compactMap {
            $0.subjectDigest == artifact.artifactDigest ? $0.validationID : nil
        })
        let validations = model.snapshot.operations.workflows.validations.filter {
            $0.targetID == artifact.artifactDigest || reportValidationIDs.contains($0.id)
        }
        guard !validations.isEmpty else { return "not validated" }
        return validations.allSatisfy { $0.outcome == .passed } ? "validated" : "validation attention"
    }

    private func previewArtifacts(_ artifacts: [DesktopWorkflowArtifactRoleRecord]) {
        let urls = artifacts.compactMap(artifactURL)
        guard !urls.isEmpty else { return }
        WorkflowArtifactPreviewController.shared.present(urls)
    }

    private func exportArtifact(_ artifact: DesktopWorkflowArtifactRoleRecord) {
        guard let data = try? model.workflowStorage(workflowID: item.workflowID)?.artifactData(
            sha256: artifact.artifactDigest
        ) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.filename
        panel.message = "Export a verified copy. Kaname keeps the immutable workflow artifact in private storage."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func reviewPurge() {
        guard let storage = model.workflowStorage(workflowID: item.workflowID),
              let plan = model.previewWorkflowPurge(workflowID: item.workflowID, mode: .manual) else { return }
        let alert = NSAlert()
        alert.messageText = "Purge eligible private workflow content?"
        alert.informativeText = "Eligible: \(plan.eligibleDigests.count) artifact(s), \(ByteCountFormatter.string(fromByteCount: Int64(plan.eligibleBytes), countStyle: .file))\nRetained: \(plan.retained.count) artifact(s)\n\nPromoted artifacts and unresolved-effect evidence remain. A sanitized receipt records counts and reasons, never deleted content."
        alert.alertStyle = .warning
        if plan.eligibleDigests.isEmpty {
            alert.addButton(withTitle: "Done")
            _ = alert.runModal()
            return
        }
        alert.addButton(withTitle: "Purge eligible content")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if try model.executeWorkflowPurge(plan, storage: storage) == nil {
                _ = model.recordWorkflowOperationalStatus(
                    workflowID: item.workflowID, relatedID: item.workflowID, kind: .retentionFailure,
                    level: .actionRequired, summary: "The purge plan changed before execution; review it again."
                )
            } else {
                _ = model.recordWorkflowOperationalStatus(
                    workflowID: item.workflowID, relatedID: item.workflowID, kind: .retentionFailure,
                    level: .actionRequired, summary: "The latest retention operation completed.", active: false
                )
            }
        } catch {
            _ = model.recordWorkflowOperationalStatus(
                workflowID: item.workflowID, relatedID: item.workflowID, kind: .retentionFailure,
                level: .actionRequired, summary: "Retention cleanup failed safely: \(error.localizedDescription)"
            )
        }
    }
}

private struct WorkflowRunGraphProjectionView: View {
    @ObservedObject var model: DesktopAppModel
    let run: DesktopWorkflowRunRecord

    private var nodes: [DesktopWorkflowRunNodeProjection] { model.workflowRunProjection(runID: run.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(run.retryMode.label, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(run.state.label).font(.caption2).foregroundStyle(.secondary)
                Button("Reprocess current revision") {
                    _ = model.queueWorkflowDebugRun(priorRunID: run.id, action: .reprocessCurrentRevision)
                }
                .font(.caption2)
                .disabled(![.completed, .failed, .cancelled].contains(run.state))
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(nodes) { node in
                        let step = revision?.steps.first { $0.id == node.stepID }
                        let attempts = model.snapshot.operations.workflows.stepAttempts.filter {
                            $0.runID == run.id && $0.stepID == node.stepID
                        }.sorted { $0.attempt < $1.attempt }
                        let transition = model.snapshot.operations.workflows.transitionRecords.last {
                            $0.runID == run.id && $0.fromStepID == node.stepID
                        }
                        let effects = model.snapshot.operations.workflows.effects.filter {
                            $0.runID == run.id && $0.stepID == node.stepID
                        }
                        let batchItems = model.snapshot.operations.workflows.batchItems.filter {
                            $0.runID == run.id && $0.stepID == node.stepID
                        }.sorted { $0.ordinal < $1.ordinal }
                        let eligibility = step.map {
                            DesktopWorkflowRunProjection.debugEligibility(
                                step: $0, projection: node,
                                hasUnknownEffect: effects.contains { $0.state == .outcomeUnknown }
                            )
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Label(node.stepID, systemImage: symbol(node.state))
                                .font(.caption.weight(.semibold))
                            Text(node.state.label).font(.caption2)
                            if let elapsed = node.elapsedMilliseconds {
                                Text("\(elapsed) ms · attempt \(node.attempt)").font(.caption2).foregroundStyle(.secondary)
                            }
                            if node.totalItems > 0 {
                                Text("Batch \(node.completedItems)/\(node.totalItems) · \(node.failedItems) failed · \(node.unknownItems) unknown")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(node.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            DisclosureGroup("Inspect step") {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let step {
                                        Text("\(step.kind.label) · \(step.capabilityID ?? "host structural step")")
                                        Text("Retry limit \(step.retryLimit) · \(step.isIdempotent ? "idempotent" : "not idempotent")")
                                    }
                                    ForEach(attempts) { attempt in
                                        Text("Attempt \(attempt.attempt) · \(attempt.state.label) · input \(attempt.inputDigest.prefix(10)) · output \(attempt.outputDigest?.prefix(10) ?? "none")")
                                    }
                                    if let transition {
                                        Text("Branch \(transition.outcome.rawValue) → \(transition.toStepID ?? "terminal")")
                                    }
                                    if !effects.isEmpty {
                                        Text("Effects: \(effects.map { $0.state.rawValue }.joined(separator: ", "))")
                                    }
                                    if !batchItems.isEmpty {
                                        ForEach(batchItems) { item in
                                            Text("Item \(item.ordinal + 1) · \(item.state.rawValue) · attempt \(item.attempt)")
                                        }
                                        let failedIDs = Set(batchItems.filter { $0.state == .failed }.map(\.id))
                                        let unknownItems = batchItems.filter { $0.state == .unknown }
                                        HStack {
                                            Button("Retry failed items") {
                                                _ = model.retryFailedWorkflowBatchItems(ids: failedIDs)
                                            }
                                            .disabled(failedIDs.isEmpty)
                                            Button("Reconcile unknown…") {
                                                reconcileUnknownBatchAsFailed(unknownItems)
                                            }
                                            .disabled(unknownItems.isEmpty)
                                        }
                                    }
                                    HStack {
                                        Button("Retry step") {
                                            _ = model.queueWorkflowDebugRun(
                                                priorRunID: run.id, action: .retryFailedStep, stepID: node.stepID
                                            )
                                        }
                                        .disabled(eligibility?.allowed.contains(.retryFailedStep) != true)
                                        Button("Restart after") {
                                            _ = model.queueWorkflowDebugRun(
                                                priorRunID: run.id, action: .restartFromCheckpoint, stepID: node.stepID
                                            )
                                        }
                                        .disabled(eligibility?.allowed.contains(.restartFromCheckpoint) != true)
                                    }
                                    if node.state == .outcomeUnknown {
                                        Label("Reconcile this effect in Effects before retrying.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                            .foregroundStyle(KanameColor.danger)
                                    }
                                }
                                .font(.caption2)
                                .padding(.top, 4)
                            }
                        }
                        .padding(9)
                        .frame(width: 250, alignment: .leading)
                        .background(tint(node.state).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint(node.state), lineWidth: 1))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(node.stepID), \(node.state.label). \(node.detail)")
                    }
                }
            }
        }
        .padding(10)
        .background(KanameColor.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }

    private var revision: DesktopWorkflowRevisionRecord? {
        model.snapshot.operations.workflows.revisions.first { $0.id == run.workflowRevisionID }
    }

    private func reconcileUnknownBatchAsFailed(_ items: [DesktopWorkflowBatchItemRecord]) {
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Record verified failure for unknown batch items?"
        alert.informativeText = "Use this only after checking the external system and confirming these \(items.count) item(s) did not succeed. They can then be retried explicitly."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Record verified failure")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for item in items {
            _ = model.reconcileUnknownWorkflowBatchItem(
                id: item.id, outcomeKnown: true, succeeded: false,
                detail: "Operator verified that the interrupted item did not succeed externally."
            )
        }
    }

    private func symbol(_ state: DesktopWorkflowRunNodeState) -> String {
        switch state {
        case .notRun: "circle"
        case .queued: "list.number"
        case .running: "progress.indicator"
        case .waiting: "clock.badge"
        case .needsReview: "person.crop.circle.badge.exclamationmark"
        case .retrying: "arrow.clockwise.circle"
        case .succeeded: "checkmark.circle.fill"
        case .skipped: "forward.end.circle"
        case .failed: "xmark.octagon.fill"
        case .outcomeUnknown: "exclamationmark.arrow.triangle.2.circlepath"
        case .cancelled: "stop.circle"
        }
    }

    private func tint(_ state: DesktopWorkflowRunNodeState) -> Color {
        switch state {
        case .succeeded: KanameColor.success
        case .failed, .outcomeUnknown: KanameColor.danger
        case .waiting, .retrying: KanameColor.warning
        case .needsReview: KanameColor.blocked
        case .running, .queued: KanameColor.accent
        default: .secondary
        }
    }
}

private struct WorkflowRunComparisonView: View {
    let comparisons: [DesktopWorkflowRunStepComparison]

    var body: some View {
        DisclosureGroup("Compare latest two runs") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(comparisons) { comparison in
                    HStack {
                        Text(comparison.stepID).font(.caption.weight(.semibold)).frame(width: 160, alignment: .leading)
                        Text(comparison.leftState.label).font(.caption2)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(comparison.rightState.label).font(.caption2)
                        Spacer()
                        if comparison.inputChanged { Label("Input", systemImage: "arrow.triangle.2.circlepath").font(.caption2) }
                        if comparison.outputChanged { Label("Output", systemImage: "arrow.triangle.2.circlepath").font(.caption2) }
                        if comparison.branchChanged { Label("Branch", systemImage: "arrow.triangle.branch").font(.caption2) }
                        if let delta = comparison.durationDeltaMilliseconds {
                            Text("\(delta >= 0 ? "+" : "")\(delta) ms").font(.caption2.monospacedDigit())
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 8)
        }
        .font(.caption)
    }
}

private struct WorkflowEpisodeRow: View {
    @ObservedObject var model: DesktopAppModel
    let episode: DesktopWorkflowEpisodeRecord

    private var runs: [DesktopWorkflowRunRecord] { model.workflowRuns(episodeID: episode.id) }
    private var validations: [DesktopWorkflowValidationRecord] { model.workflowValidations(episodeID: episode.id) }
    private var reports: [DesktopWorkflowValidatorReportRecord] {
        let validationIDs = Set(validations.map(\.id))
        return model.snapshot.operations.workflows.validatorReports.filter { validationIDs.contains($0.validationID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent {
                Text(episode.state.label).font(.caption2).foregroundStyle(.secondary)
            } label: {
                Label(
                    "Episode \(episode.ordinal) · \(episode.intent.label)",
                    systemImage: episode.state == .superseded ? "arrow.uturn.forward.circle" : "circle.inset.filled"
                )
                .font(.caption.weight(.semibold)).foregroundStyle(episode.state.tint)
            }
            Text(episode.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            WorkflowEpisodeMetrics(runs: runs, validations: validations)
            if episode.state == .superseded {
                Text("Superseded by a later episode; retained as evidence and excluded from current truth by default.")
                    .font(.caption2).foregroundStyle(KanameColor.warning)
            }
            if !validations.isEmpty {
                WorkflowValidationEvidence(validations: validations, reports: reports)
            }
        }
        .padding(10)
        .background(KanameColor.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct WorkflowEpisodeMetrics: View {
    let runs: [DesktopWorkflowRunRecord]
    let validations: [DesktopWorkflowValidationRecord]

    var body: some View {
        HStack(spacing: 12) {
            Label("\(runs.count) run\(runs.count == 1 ? "" : "s")", systemImage: "waveform.path.ecg")
            Label("\(validations.filter { $0.outcome == .passed }.count) passed", systemImage: "checkmark.circle")
            let blocking = validations.filter { $0.severity == .blocking && $0.outcome != .passed }.count
            if blocking > 0 {
                Label("\(blocking) blocking", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(KanameColor.warning)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}

private struct WorkflowValidationEvidence: View {
    let validations: [DesktopWorkflowValidationRecord]
    let reports: [DesktopWorkflowValidatorReportRecord]

    var body: some View {
        DisclosureGroup("Validation evidence · \(validations.count)") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(validations) { validation in
                    let matchingReports = reports.filter { $0.validationID == validation.id }
                    VStack(alignment: .leading, spacing: 3) {
                        LabeledContent {
                            Text(validation.outcome.label)
                                .foregroundStyle(validation.outcome == .passed ? KanameColor.success : KanameColor.warning)
                        } label: {
                            Text(validation.validatorID).fontWeight(.semibold)
                        }
                        Text(validation.summary).foregroundStyle(.secondary)
                        ForEach(matchingReports) { report in
                            Text("Validator \(report.validatorVersion) · subject \(report.subjectDigest.prefix(12))")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            ForEach(report.findings) { finding in
                                Label(finding.summary, systemImage: finding.severity == .blocking
                                    ? "exclamationmark.triangle.fill" : "info.circle")
                                Text(finding.evidence).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.caption2)
    }
}

struct WorkflowDefinitionCard: View {
    @ObservedObject var model: DesktopAppModel
    let definition: DesktopWorkflowDefinitionRecord
    let googleAccounts: [NativeGoogleAccountSnapshot]
    let runManually: () -> Void
    let configureInstallation: (DesktopWorkflowInstallationRecord) -> Void
    let processExistingMatches: (DesktopWorkflowTriggerBindingRecord) -> Void
    @State private var selectedAccountID = ""
    @State private var emailFilter = ""
    @State private var transferMessage: String?
    @State private var ownershipFilter = ""
    @State private var ownershipMode = DesktopWorkflowOwnershipMode.protected
    @State private var scheduleTime = Date()
    @State private var scheduleZone = TimeZone.current.identifier
    @State private var missedRunPolicy = DesktopAutomationRule.MissedRunPolicy.skip
    @State private var selectedCalendarSourceID = ""

    private var emailTriggerBindings: [DesktopWorkflowTriggerBindingRecord] {
        model.workflowTriggerBindings(workflowID: definition.id).filter { $0.trigger == .email }
    }

    private var calendarTriggerBindings: [DesktopWorkflowTriggerBindingRecord] {
        model.workflowTriggerBindings(workflowID: definition.id).filter { $0.trigger == .calendar }
    }

    private var googleCalendarSources: [DesktopCalendarSourceRecord] {
        model.snapshot.domains.calendarSources.filter { source in
            source.provider == .google && source.isEnabled
                && googleAccounts.contains { $0.identity == source.ownerIdentity }
        }
    }

    private var googleAccountPicker: some View {
        Picker("Account", selection: $selectedAccountID) {
            Text("Choose account").tag("")
            ForEach(googleAccounts) { account in Text(account.identity).tag(account.id) }
        }
        .frame(maxWidth: 220)
    }

    private var revision: DesktopWorkflowRevisionRecord? {
        model.snapshot.operations.workflows.revisions.first { $0.id == definition.currentRevisionID }
    }

    private var catalogFixtureSuite: DesktopWorkflowFixtureSuite? {
        DesktopWorkflowStarterCatalog.fixtureSuites.first { $0.workflowID == definition.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkflowDefinitionHeader(model: model, definition: definition)
            HStack(spacing: 8) {
                if definition.triggerKinds.contains(.manual) {
                    Button("Run…", systemImage: "play.fill", action: runManually)
                        .buttonStyle(.borderedProminent)
                        .disabled(!definition.enabled)
                }
                Button("Export package…", systemImage: "shippingbox.and.arrow.backward") {
                    do {
                        transferMessage = try DesktopWorkflowTransferUI.exportPackage(model: model, definition: definition)
                    } catch {
                        transferMessage = error.localizedDescription
                    }
                }
                Button("Export installation…", systemImage: "lock.doc") {
                    do {
                        transferMessage = try DesktopWorkflowTransferUI.exportInstallation(model: model, definition: definition)
                    } catch {
                        transferMessage = error.localizedDescription
                    }
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            if let transferMessage {
                Label(transferMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let revision {
                let readiness = model.workflowMigrationReadiness(workflowID: definition.id)
                WorkflowMetricsRow(metrics: [
                    WorkflowMetricValue(label: "Revision", value: revision.version, tint: KanameColor.active),
                    WorkflowMetricValue(label: "Steps", value: "\(revision.steps.count)", tint: KanameColor.accent),
                    WorkflowMetricValue(label: "Permissions", value: "\(revision.permissions.permissions.count)", tint: KanameColor.warning)
                ])
                if revision.schemaVersion == 3 {
                    DisclosureGroup("Installations · \(model.workflowInstallations(workflowID: definition.id).count)") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.workflowInstallations(workflowID: definition.id)) { installation in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: installation.readinessIssues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(installation.readinessIssues.isEmpty ? KanameColor.success : KanameColor.warning)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(installation.name).font(.caption.weight(.semibold))
                                        Text(installation.readinessIssues.isEmpty
                                            ? "Configuration and bindings are ready; authority remains separate."
                                            : installation.readinessIssues.joined(separator: " · "))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                    Spacer()
                                    Button("Configure…") { configureInstallation(installation) }
                                    Toggle("Enabled", isOn: Binding(
                                        get: { installation.enabled },
                                        set: { _ = model.setWorkflowInstallationEnabled(id: installation.id, enabled: $0) }
                                    ))
                                    .labelsHidden()
                                    .disabled(!installation.readinessIssues.isEmpty && !installation.enabled)
                                }
                            }
                            Button("Add another installation") {
                                do {
                                    let id = try model.createWorkflowInstallation(
                                        workflowID: definition.id,
                                        name: "\(definition.name) \(model.workflowInstallations(workflowID: definition.id).count + 1)"
                                    )
                                    if let created = model.snapshot.operations.workflows.installations.first(where: { $0.id == id }) {
                                        configureInstallation(created)
                                    }
                                } catch { transferMessage = error.localizedDescription }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(readiness.checks) { check in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: readinessSymbol(check.state))
                                    .foregroundStyle(readinessTint(check.state))
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(check.title).font(.caption.weight(.semibold))
                                    Text(check.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Label("Host readiness", systemImage: readiness.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(readiness.isReady ? KanameColor.success : KanameColor.warning)
                        Spacer()
                        Text(readiness.isReady ? "Ready to configure" : "\(readiness.blockedCount) blocked")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("Stages and permission receipt") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(revision.steps) { step in
                            HStack {
                                Image(systemName: step.kind.symbol).foregroundStyle(KanameColor.accent).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.name).font(.caption.weight(.semibold))
                                    Text(step.kind.label + (step.capabilityID.map { " · \($0)" } ?? ""))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    let artifactCount = step.artifactInputs?.count ?? 0
                                    let stateCount = step.stateInputs?.count ?? 0
                                    if artifactCount + stateCount > 0 {
                                        Text("Declared inputs · \(artifactCount) artifact role\(artifactCount == 1 ? "" : "s") · \(stateCount) state value\(stateCount == 1 ? "" : "s")")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let transitions = step.transitions, !transitions.isEmpty {
                                        Text("Routes · " + transitions.map { "\($0.outcome.rawValue) → \($0.targetStepID)" }.joined(separator: " · "))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    if step.reviewContract != nil {
                                        Text("Schema-driven human decision").font(.caption2).foregroundStyle(KanameColor.warning)
                                    } else if step.waitContract != nil {
                                        Text("Durable resumable subscription").font(.caption2).foregroundStyle(KanameColor.active)
                                    } else if step.agentPolicy != nil {
                                        Text("Bounded agent · no direct effects").font(.caption2).foregroundStyle(KanameColor.active)
                                    }
                                }
                                Spacer()
                                if !step.isIdempotent { Text("No automatic retry").font(.caption2).foregroundStyle(KanameColor.warning) }
                            }
                        }
                        Divider()
                        if revision.permissions.permissions.isEmpty {
                            Text("Local read-only workflow").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(revision.permissions.permissions, id: \.self) { permission in
                                Label(permission.label, systemImage: permission.symbol).font(.caption)
                            }
                        }
                        LabeledContent("Manifest digest", value: String(revision.manifestDigest.prefix(20)) + "…")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let datasets = revision.datasetDefinitions, !datasets.isEmpty {
                            Divider()
                            Text("Declared datasets").font(.caption.weight(.semibold))
                            ForEach(datasets) { dataset in
                                WorkflowDatasetSummaryRow(
                                    definition: dataset,
                                    rowCount: model.snapshot.operations.workflows.datasetRows.filter {
                                        $0.workflowID == definition.id && $0.datasetID == dataset.id
                                    }.count
                                )
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                if definition.triggerKinds.contains(.email) {
                    DisclosureGroup("Email trigger scope") {
                        VStack(alignment: .leading, spacing: 10) {
                            if emailTriggerBindings.isEmpty {
                                Text("No mailbox is observed until you add and enable an account-scoped filter.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(emailTriggerBindings) { binding in
                                    WorkflowTriggerBindingRow(
                                        model: model, binding: binding,
                                        processExistingMatches: { processExistingMatches(binding) },
                                        rebaseline: nil
                                    )
                                }
                            }
                            if !googleAccounts.isEmpty {
                                HStack {
                                    googleAccountPicker
                                    TextField("Provider filter, for example from:sender@example.com", text: $emailFilter)
                                    Button("Add scope") {
                                        _ = model.bindWorkflowTrigger(
                                            workflowID: definition.id, trigger: .email, source: "mail",
                                            accountIDs: [selectedAccountID], sourceFilter: emailFilter, enabled: false
                                        )
                                        emailFilter = ""
                                    }
                                    .disabled(selectedAccountID.isEmpty || emailFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            } else {
                                Text("Connect a mail account to configure an email trigger.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 8)
                    }
                    DisclosureGroup("Ownership and exclusions") {
                        Form {
                            Section("Current policy") {
                                let policies = model.snapshot.operations.workflows.ownershipPolicies.filter { $0.workflowID == definition.id }
                                WorkflowOwnershipPolicySummary(policies: policies)
                            }
                            Section("Add policy") {
                                HStack {
                                    googleAccountPicker
                                    TextField("Protected sender or exact query", text: $ownershipFilter)
                                    Picker("Mode", selection: $ownershipMode) {
                                        ForEach(DesktopWorkflowOwnershipMode.allCases, id: \.self) { Text($0.label).tag($0) }
                                    }
                                    Button("Add") {
                                        _ = model.upsertWorkflowOwnershipPolicy(
                                            workflowID: definition.id, accountID: selectedAccountID,
                                            sourceFilter: ownershipFilter, mode: ownershipMode
                                        )
                                        ownershipFilter = ""
                                    }
                                    .disabled(selectedAccountID.isEmpty || ownershipFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }
                        .formStyle(.grouped)
                    }
                }
                if definition.triggerKinds.contains(.calendar) {
                    DisclosureGroup("Calendar trigger scope") {
                        VStack(alignment: .leading, spacing: 10) {
                            if calendarTriggerBindings.isEmpty {
                                Text("No calendar is observed until you add and enable an exact source.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(calendarTriggerBindings) { binding in
                                    WorkflowTriggerBindingRow(
                                        model: model, binding: binding,
                                        processExistingMatches: nil,
                                        rebaseline: { _ = model.rebaselineWorkflowTrigger(id: binding.id) }
                                    )
                                }
                            }
                            if googleCalendarSources.isEmpty {
                                Text("Connect Google Calendar and enable a visible calendar first.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                HStack {
                                    Picker("Calendar", selection: $selectedCalendarSourceID) {
                                        Text("Choose calendar").tag("")
                                        ForEach(googleCalendarSources) { source in
                                            Text("\(source.displayName) · \(source.ownerIdentity)").tag(source.id)
                                        }
                                    }
                                    .frame(maxWidth: 360)
                                    Button("Add scope") {
                                        guard let source = googleCalendarSources.first(where: {
                                            $0.id == selectedCalendarSourceID
                                        }), let account = googleAccounts.first(where: {
                                            $0.identity == source.ownerIdentity
                                        }) else { return }
                                        _ = model.bindWorkflowTrigger(
                                            workflowID: definition.id, trigger: .calendar,
                                            source: "google-calendar", accountIDs: [account.id],
                                            sourceFilter: source.externalIdentifier, enabled: false
                                        )
                                        selectedCalendarSourceID = ""
                                    }
                                    .disabled(selectedCalendarSourceID.isEmpty)
                                }
                            }
                            Text("The first enabled check establishes a baseline. Later event revisions create durable episodes; the trigger grants no calendar-write authority.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }
                }
                if definition.triggerKinds.contains(.schedule) {
                    DisclosureGroup("Schedule trigger") {
                        Grid(alignment: .leading, verticalSpacing: 10) {
                            let schedules = model.snapshot.operations.workflows.scheduleBindings.filter { $0.workflowID == definition.id }
                            ForEach(schedules) { schedule in
                                LabeledContent {
                                    Text(schedule.enabled ? "Enabled" : "Paused")
                                        .font(.caption).foregroundStyle(schedule.enabled ? KanameColor.success : .secondary)
                                } label: {
                                    Text(DesktopScheduleEngine.humanSchedule(spec: schedule.spec, timeZoneIdentifier: schedule.timeZoneIdentifier))
                                        .font(.caption)
                                }
                            }
                            HStack {
                                DatePicker("Daily at", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                                TextField("Time zone", text: $scheduleZone).frame(width: 180)
                                Picker("Missed run", selection: $missedRunPolicy) {
                                    ForEach(DesktopAutomationRule.MissedRunPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                Button("Add schedule") {
                                    var calendar = Calendar(identifier: .gregorian)
                                    calendar.timeZone = TimeZone(identifier: scheduleZone) ?? .current
                                    let components = calendar.dateComponents([.hour, .minute], from: scheduleTime)
                                    _ = model.upsertWorkflowSchedule(
                                        workflowID: definition.id,
                                        spec: .anchored(frequency: .daily, hour: components.hour ?? 9, minute: components.minute ?? 0),
                                        timeZoneIdentifier: scheduleZone, missedRunPolicy: missedRunPolicy, enabled: true
                                    )
                                }
                                .disabled(TimeZone(identifier: scheduleZone) == nil)
                            }
                            Text("A schedule starts the workflow but never grants mailbox or connector authority by itself.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }
                }
                workflowMigrationAcceptance
            }
        }
        .panelStyle()
    }

    @ViewBuilder
    private var workflowMigrationAcceptance: some View {
        let assessment = model.snapshot.operations.workflows.migrationAssessments
            .filter { $0.workflowID == definition.id }
            .sorted { ($0.updatedAtUnixMillis, $0.id) > ($1.updatedAtUnixMillis, $1.id) }
            .first
        DisclosureGroup("Migration acceptance") {
            VStack(alignment: .leading, spacing: 9) {
                if let assessment {
                    LabeledContent("Stage", value: assessment.stage.label)
                    Text("\(assessment.passedScenarioIDs.count) of \(assessment.requiredScenarioIDs.count) required scenarios passed")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(assessment.comparisonEvidenceIDs?.count ?? 0) integrity-bound comparison receipt(s)")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let fixtureSuiteID = assessment.fixtureSuiteID,
                       let fixtureSuiteDigest = assessment.fixtureSuiteDigest {
                        Text("\(fixtureSuiteID) · \(fixtureSuiteDigest.prefix(16))…")
                            .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    ForEach(assessment.blockingFindings, id: \.self) { finding in
                        Label(finding, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(KanameColor.warning)
                    }
                    if let current = DesktopWorkflowMigrationStage.allCases.firstIndex(of: assessment.stage),
                       DesktopWorkflowMigrationStage.allCases.indices.contains(current + 1) {
                        Button("Advance to \(DesktopWorkflowMigrationStage.allCases[current + 1].label)") {
                            do {
                                try model.advanceWorkflowMigration(
                                    id: assessment.id, to: DesktopWorkflowMigrationStage.allCases[current + 1]
                                )
                            } catch { transferMessage = error.localizedDescription }
                        }
                        .disabled(!assessment.blockingFindings.isEmpty
                            || !Set(assessment.requiredScenarioIDs).isSubset(of: Set(assessment.passedScenarioIDs)))
                    }
                } else {
                    Text("Start with observe-only evidence. Live effects remain outside the comparison harness.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Create acceptance checklist") {
                        _ = model.createWorkflowMigrationAssessment(
                            workflowID: definition.id,
                            requiredScenarioIDs: [
                                "fixture-parity", "backup-restore", "restart-resume", "unknown-outcome",
                                "account-expiry", "large-artifact", "correction-thread", "rollback",
                            ]
                        )
                    }
                }
                if let suite = catalogFixtureSuite {
                    Button("Run signed-package synthetic qualification", systemImage: "checkmark.seal") {
                        qualifySyntheticPackage(suite)
                    }
                    Text("Runs deterministic mail, model, connector, failure, and replay fixtures. The comparison baseline is synthetic package evidence, not private legacy acceptance.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    private func qualifySyntheticPackage(_ suite: DesktopWorkflowFixtureSuite) {
        do {
            let installation = model.workflowInstallations(workflowID: definition.id).first {
                $0.workflowRevisionID == definition.currentRevisionID
            }
            let requiredScenarios = Set(suite.cases.map(\.id))
            let assessmentID = model.snapshot.operations.workflows.migrationAssessments.first {
                $0.workflowID == definition.id
                    && Set($0.requiredScenarioIDs) == requiredScenarios
                    && ($0.fixtureSuiteDigest == nil || $0.fixtureSuiteDigest == suite.digest)
            }?.id ?? model.createWorkflowMigrationAssessment(
                workflowID: definition.id,
                requiredScenarioIDs: requiredScenarios.sorted(),
                installationID: installation?.id
            )
            guard let assessmentID else {
                throw DesktopWorkflowSimulationError.staleEvidence
            }
            for scenario in suite.cases {
                let runID = try model.simulateWorkflowFixture(
                    workflowID: definition.id, installationID: installation?.id,
                    suite: suite, scenarioID: scenario.id
                )
                guard let run = model.snapshot.operations.workflows.simulationRuns.first(where: { $0.id == runID }) else {
                    throw DesktopWorkflowSimulationError.expectationFailed
                }
                _ = try model.recordWorkflowMigrationComparison(
                    assessmentID: assessmentID, simulationRunID: runID,
                    legacySourceRevision: "synthetic-package-baseline@\(suite.digest)",
                    legacyOutputJSON: run.outputJSON
                )
            }
            transferMessage = "Synthetic qualification passed with exact package, dependency, fixture, timeline, and comparison receipts."
        } catch {
            transferMessage = "Synthetic qualification failed safely: \(error.localizedDescription)"
        }
    }

    private func readinessSymbol(_ state: DesktopWorkflowMigrationReadinessState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .blocked: "xmark.circle.fill"
        }
    }

    private func readinessTint(_ state: DesktopWorkflowMigrationReadinessState) -> Color {
        switch state {
        case .ready: KanameColor.success
        case .attention: KanameColor.warning
        case .blocked: KanameColor.danger
        }
    }
}

private struct WorkflowOwnershipPolicySummary: View {
    let policies: [DesktopWorkflowOwnershipPolicyRecord]

    var body: some View {
        Text(policies.isEmpty
            ? "Protect correspondence from broad cleanup workflows, or allow shared read-only observation explicitly."
            : policies.map {
                "\($0.enabled ? "Active" : "Paused") · \($0.mode.label)\n\($0.sourceFilter) · \($0.accountID)"
            }.joined(separator: "\n\n")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}

struct WorkflowManualRunSheet: View {
    let definition: DesktopWorkflowDefinitionRecord
    let revision: DesktopWorkflowRevisionRecord?
    let start: (String, String, Data) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var request = ""
    @State private var input = "{}"
    @State private var values: [String: String] = [:]
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run \(definition.name)").font(.title2.weight(.bold))
            Text("This creates durable work and runs the exact installed revision. It does not change email unless a later reviewed effect is approved.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Work title", text: $title)
            TextField("What should this run accomplish?", text: $request, axis: .vertical)
                .lineLimit(2...5)
            if formFields.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Structured input").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $input)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(6)
                        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Manual workflow JSON input")
                }
            } else {
                Form {
                    Section("Run input") {
                        WorkflowSchemaFormView(fields: formFields, values: $values)
                    }
                }
                .formStyle(.grouped)
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(KanameColor.warning)
            }
            DesktopSheetActionBar(
                primaryTitle: "Start run",
                isPrimaryEnabled: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                dismiss: dismiss.callAsFunction,
                performPrimary: submit
            )
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            title = definition.name
            for field in formFields where values[field.pointer] == nil {
                guard let value = field.defaultJSON else { continue }
                if field.control == .picker { values[field.pointer] = value }
                else if let data = value.data(using: .utf8),
                        let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    values[field.pointer] = decoded as? String ?? String(describing: decoded)
                }
            }
        }
    }

    private var formFields: [DesktopWorkflowFormField] {
        guard let schema = revision?.manualRunInputSchema else { return [] }
        return DesktopWorkflowSchemaForm.fields(schemaText: schema, hints: revision?.uiHints ?? [])
    }

    private func submit() {
        guard let data = formFields.isEmpty ? input.data(using: .utf8) : encodedForm(),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            validationMessage = "Enter valid JSON input."
            return
        }
        if start(title, request, data) { dismiss() }
        else { validationMessage = "Kaname could not queue this run. Review the workflow readiness details." }
    }

    private func encodedForm() -> Data? {
        var object: [String: Any] = [:]
        for field in formFields {
            let raw = values[field.pointer] ?? ""
            if raw.isEmpty && !field.required { continue }
            let key = String(field.pointer.dropFirst()).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch field.type {
            case "boolean": object[key] = raw == "true"
            case "integer": guard let value = Int(raw) else { return nil }; object[key] = value
            case "number": guard let value = Double(raw) else { return nil }; object[key] = value
            default:
                if field.control == .picker, let data = raw.data(using: .utf8),
                   let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    object[key] = decoded
                } else { object[key] = raw }
            }
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private struct WorkflowMetricValue: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let tint: Color
}

private struct WorkflowMetricsRow: View {
    let metrics: [WorkflowMetricValue]

    var body: some View {
        Grid(horizontalSpacing: 8) {
            GridRow {
                ForEach(metrics) { metric in
                    LabeledContent {
                        Text(metric.value).font(.caption.weight(.semibold)).foregroundStyle(metric.tint)
                    } label: {
                        Text(metric.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct WorkflowDefinitionHeader: View {
    @ObservedObject var model: DesktopAppModel
    let definition: DesktopWorkflowDefinitionRecord

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12) {
            GridRow {
                Image(systemName: definition.icon)
                    .font(.title2)
                    .foregroundStyle(definition.enabled ? KanameColor.accent : .secondary)
                Grid(alignment: .leading, verticalSpacing: 4) {
                    GridRow { Text(definition.name).font(.headline) }
                    GridRow { Text(definition.summary).font(.caption).foregroundStyle(.secondary) }
                    GridRow { Text("\(definition.source) · \(definition.license)").font(.caption2).foregroundStyle(.secondary) }
                }
                Toggle("Enabled", isOn: Binding(
                    get: { definition.enabled },
                    set: { _ = model.setWorkflowEnabled(id: definition.id, enabled: $0) }
                ))
            }
        }
    }
}

private struct WorkflowTriggerBindingRow: View {
    @ObservedObject var model: DesktopAppModel
    let binding: DesktopWorkflowTriggerBindingRecord
    let processExistingMatches: (() -> Void)?
    let rebaseline: (() -> Void)?

    var body: some View {
        let health = model.snapshot.operations.workflows.triggerHealth.first { $0.bindingID == binding.id }
        LabeledContent {
            HStack {
                if let processExistingMatches {
                    Button("Process existing…", action: processExistingMatches)
                        .help("Preview and create workflow episodes for existing provider matches without changing mail")
                }
                if let rebaseline {
                    Button("Rebaseline", action: rebaseline)
                        .help("Discard only the expired source cursor and establish a new baseline without replaying existing items")
                }
                Toggle("Observe", isOn: Binding(
                    get: { binding.enabled },
                    set: { _ = model.setWorkflowTriggerPaused(bindingID: binding.id, paused: !$0) }
                ))
                .labelsHidden()
            }
        } label: {
            Label {
                Grid(alignment: .leading, verticalSpacing: 2) {
                    GridRow { Text(binding.sourceFilter).font(.caption.weight(.semibold)) }
                    GridRow {
                        Text("\(binding.accountIDs.count) account scope · \(binding.lastCursor == nil ? "No cursor yet" : "Cursor established")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let health {
                        GridRow {
                            Text(health.state.label + (health.lastSuccessAtUnixMillis.map { " · last verified " + Date(timeIntervalSince1970: Double($0) / 1_000).formatted(date: .abbreviated, time: .shortened) } ?? ""))
                                .font(.caption2)
                                .foregroundStyle(health.state == .actionRequired ? KanameColor.warning : .secondary)
                        }
                    }
                }
            } icon: {
                Image(systemName: binding.trigger == .calendar ? "calendar.badge.clock" : "line.3.horizontal.decrease.circle")
            }
        }
    }
}

private extension DesktopWorkflowWorkState {
    var symbol: String {
        KanameDesktopStatusPresentation.workflow(self).symbolName
    }

    var tint: Color {
        KanameDesktopStatusPresentation.workflow(self).tone.color
    }
}

private extension DesktopWorkflowStepKind {
    var symbol: String {
        switch self {
        case .classifyEvent: "text.magnifyingglass"
        case .correlateWork: "link"
        case .compileContext: "square.stack.3d.up"
        case .structuredModel: "brain"
        case .invokeTool: "wrench.and.screwdriver"
        case .registerArtifact: "doc.badge.plus"
        case .validate: "checkmark.shield"
        case .branch: "arrow.triangle.branch"
        case .match: "arrow.triangle.swap"
        case .forEach: "square.stack.3d.down.right"
        case .agent: "brain.head.profile"
        case .effect: "bolt.horizontal.circle"
        case .humanReview: "person.crop.circle.badge.questionmark"
        case .requestApproval: "hand.raised"
        case .createEmailDraft: "square.and.pencil"
        case .sendEmail: "paperplane"
        case .waitForEmail: "envelope.badge"
        case .complete: "checkmark.circle"
        }
    }
}

private extension DesktopWorkflowPermission {
    var symbol: String {
        switch self {
        case .emailRead: "envelope.open"
        case .emailDraft: "square.and.pencil"
        case .emailSend: "paperplane"
        case .emailLabels: "tag"
        case .fileRead: "doc.text.magnifyingglass"
        case .fileWrite: "doc.badge.arrow.up"
        case .modelEgress: "brain"
        case .network: "network"
        case .externalEffects: "bolt.horizontal.circle"
        }
    }
}

struct DesktopAutomationsView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var scheduler: DesktopAutomationSchedulerViewModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    let deepLink: DesktopAutomationDeepLink?

    var body: some View {
        Group {
            if CommandLine.arguments.contains("--desktop-automation-workflows-prototype") {
                AutomationWorkflowDesignPreview()
            } else {
                AutomationWorkflowProductView(
                    model: model,
                    scheduler: scheduler,
                    integrations: integrations,
                    deepLink: deepLink
                )
            }
        }
    }
}
