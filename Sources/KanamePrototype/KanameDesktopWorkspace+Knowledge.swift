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

struct DesktopResearchView: View {
    @ObservedObject var model: DesktopAppModel
    let openThread: (String) -> Void
    @State private var showsNewResearch = false
    @State private var sourceTarget: DesktopResearchRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Research",
                    detail: "Questions, source boundaries, citations, and reusable findings",
                    symbol: DesktopDestination.research.symbol
                ) {
                    Button("New research", systemImage: "plus.magnifyingglass") {
                        showsNewResearch = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                BoundaryCallout(
                    title: "Research starts with an explicit boundary",
                    detail: "Kaname keeps the question and sensitivity boundary local. A provider or remote search receives content only after that execution surface is deliberately selected."
                )

                if model.snapshot.domains.research.isEmpty {
                    EmptyPanel(
                        symbol: "text.magnifyingglass",
                        title: "No research work yet",
                        detail: "Start a durable research thread without attaching it to a coding project."
                    )
                    .frame(minHeight: 260)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(model.snapshot.domains.research.sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }) { record in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .font(.title2)
                                        .foregroundStyle(KanameColor.accent)
                                    Spacer()
                                    KanameStatusBadge(
                                        KanameDesktopStatusPresentation.record(record.status),
                                        density: .compact
                                    )
                                }
                                Text(record.title)
                                    .font(.headline)
                                Text(record.question)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                Divider()
                                LabeledContent("Sources", value: "\(record.sourceCount)")
                                    .font(.caption)
                                if let latest = model.snapshot.operations.researchSources
                                    .filter({ $0.researchID == record.id })
                                    .sorted(by: { $0.retrievedAtUnixMillis > $1.retrievedAtUnixMillis })
                                    .first {
                                    Text(latest.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Button("Add source", systemImage: "link.badge.plus") {
                                    sourceTarget = record
                                }
                                .buttonStyle(.bordered)
                                RelativeTime(unixMillis: record.updatedAtUnixMillis)
                            }
                            .panelStyle()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.canvas)
        .sheet(isPresented: $showsNewResearch) {
            NewResearchSheet(model: model) { threadID in
                openThread(threadID)
            }
        }
        .sheet(item: $sourceTarget) { research in
            NewResearchSourceSheet(model: model, research: research)
        }
    }
}

struct DesktopCodingKnowledgeLaneView: View {
    @ObservedObject var model: DesktopAppModel
    let thread: DesktopThread
    var draftKnowledge: (() -> Void)? = nil
    @StateObject private var knowledge = DesktopKnowledgeViewModel()
    @State private var targetScopeID: String?
    @State private var targetPath = ""
    @State private var waiverReason = ""

    private var lane: DesktopCodingKnowledgeLane? {
        model.codingKnowledgeLane(threadID: thread.id)
    }

    private var writableScopes: [DesktopVaultScopeRecord] {
        model.snapshot.operations.vaultScopes.filter { $0.canWrite }
    }

    private var selectedScope: DesktopVaultScopeRecord? {
        writableScopes.first { $0.id == targetScopeID }
    }

    private var activeWrite: DesktopKnowledgeWriteRecord? {
        (knowledge.activeWriteID ?? lane?.writeID).flatMap { id in
            model.snapshot.operations.knowledgeWrites.first { $0.id == id }
        }
    }

    private var knowledgeReadyForDisposition: Bool {
        guard lane?.disposition != .reconciled, lane?.disposition != .waived else { return false }
        let workflowReady = model.codingWorkflow(threadID: thread.id)?.state == .updatingKnowledge
        let acceptedWorktree = lane?.acceptedWorktreeID.flatMap { acceptedWorktreeID in
            model.snapshot.operations.worktrees.first {
                $0.id == acceptedWorktreeID && $0.threadID == thread.id
            }
        }?.state == .accepted
        return workflowReady && acceptedWorktree
    }

    private var activeProposal: DesktopKnowledgeProposal? {
        activeWrite.flatMap { write in
            model.snapshot.operations.knowledgeProposals.first { $0.id == write.proposalID }
        }
    }

    private var activeApproval: DesktopApprovalRecord? {
        activeWrite?.approvalID.flatMap { id in
            model.snapshot.operations.approvals.first { $0.id == id }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if knowledge.isBusy {
                    ProgressView("Working with local knowledge…")
                }
                if let message = knowledge.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lane {
                    knowledgeCollectionSection(
                        title: "Consulted",
                        emptyMessage: "No consulted sources were recorded.",
                        items: lane.consultedSources,
                        accessibilityLabel: "Consulted coding knowledge sources"
                    ) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.title).font(.subheadline.weight(.semibold))
                            Text(source.path).font(.caption).textSelection(.enabled)
                            Text("Digest " + source.digest + " · " + source.provenance)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    knowledgeCollectionSection(
                        title: "Candidates",
                        emptyMessage: "No candidates were recorded. An empty list does not waive the durable update.",
                        items: lane.candidates,
                        accessibilityLabel: "Coding knowledge candidates"
                    ) { candidate in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(candidate.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(candidate.category.label)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(KanameColor.accent)
                            }
                            Text(candidate.detail).font(.caption).foregroundStyle(.secondary)
                            if let digest = candidate.evidenceDigest {
                                Text("Evidence digest: " + digest)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    proposedNotesSection(lane)
                    proposalSection(lane)
                    statusSection(lane)
                } else {
                    EmptyPanel(
                        symbol: "books.vertical",
                        title: "Knowledge lane unavailable",
                        detail: "This coding result has no durable knowledge lane to review."
                    )
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.canvas)
        .onAppear {
            if targetScopeID == nil { targetScopeID = writableScopes.first?.id }
            knowledge.resumeCodingProposal(model: model, threadID: thread.id)
        }
        .onChange(of: thread.id) { _ in
            targetScopeID = writableScopes.first?.id
            targetPath = ""
            waiverReason = ""
        }
    }

    private func knowledgeCollectionSection<Item: Identifiable, Row: View>(
        title: String,
        emptyMessage: String,
        items: [Item],
        accessibilityLabel: String,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if items.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    row(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .panelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Notes the provider proposed through the Bridge after acceptance.
    private func proposedNotesSection(_ lane: DesktopCodingKnowledgeLane) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Proposed notes").font(.headline)
                Spacer()
                if knowledgeReadyForDisposition, let draftKnowledge {
                    Button("Draft knowledge update", systemImage: "sparkles", action: draftKnowledge)
                        .buttonStyle(.bordered)
                        .help("Ask the provider to propose note updates from this accepted work")
                }
            }
            let proposals = lane.noteProposals ?? []
            if proposals.isEmpty {
                Text(knowledgeReadyForDisposition
                    ? "No note proposals yet. Kaname asks the provider for one after acceptance; use the button to ask again."
                    : "Note proposals appear here after the implementation is accepted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(proposals) { proposal in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(proposal.path).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                            Spacer()
                            Button("Open as draft", systemImage: "square.and.pencil") {
                                knowledge.prepareProposedDraft(model: model, threadID: thread.id, proposal: proposal)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        if !proposal.rationale.isEmpty {
                            Text(proposal.rationale).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(proposal.content)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(8)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .panelStyle()
    }

    private func proposalSection(_ lane: DesktopCodingKnowledgeLane) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proposed edit").font(.headline)
            if let activeWrite {
                LabeledContent("Target", value: activeWrite.targetPath)
                LabeledContent("Proposal", value: activeWrite.proposalID)
                LabeledContent("Write", value: activeWrite.id)
                LabeledContent("State", value: activeWrite.state.label)
                LabeledContent("Base digest", value: activeWrite.baseDigest)
                LabeledContent("Proposed digest", value: activeWrite.proposedDigest)
                if let activeProposal {
                    Text(activeProposal.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let diff = knowledge.diff {
                    ScrollView(.horizontal) {
                        Text(diff.unifiedDiff)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                } else if !activeWrite.unifiedDiff.isEmpty {
                    ScrollView(.horizontal) {
                        Text(activeWrite.unifiedDiff)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                }
                HStack {
                    if activeApproval == nil, knowledgeReadyForDisposition {
                        Button("Request write approval", systemImage: "checkmark.shield") {
                            knowledge.requestApproval(model: model)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if activeApproval?.state == .approved, knowledgeReadyForDisposition {
                        Button("Apply approved edit", systemImage: "square.and.arrow.down") {
                            knowledge.applyApprovedDraft(model: model)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if activeApproval != nil {
                        Label("Write approval: " + (activeApproval?.state.label ?? "Unknown"), systemImage: "tray.full")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if activeWrite.state == .failed || lane.disposition == .conflict
                        || activeApproval?.state == .rejected || activeApproval?.state == .cancelled {
                        Button("Revise from current note", systemImage: "arrow.triangle.2.circlepath") {
                            let previousPath = activeWrite.targetPath
                            guard model.beginCodingKnowledgeRevision(threadID: thread.id) else { return }
                            targetPath = previousPath
                            targetScopeID = writableScopes.first(where: {
                                previousPath == $0.path || previousPath.hasPrefix($0.path + "/")
                            })?.id
                            knowledge.resumeCodingProposal(model: model, threadID: thread.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if let document = knowledge.document {
                Text("Exact note: " + document.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Current digest: " + document.digest)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                TextEditor(text: $knowledge.draft)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 230, maxHeight: 360)
                    .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Editable proposed knowledge note")
                    .disabled(!knowledgeReadyForDisposition)
                HStack {
                    Button("Review exact diff", systemImage: "doc.text.magnifyingglass") {
                        knowledge.reviewDraft(model: model, codingThreadID: thread.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!knowledgeReadyForDisposition || knowledge.isBusy)
                    Button("Reset draft", systemImage: "arrow.uturn.backward") { knowledge.resetDraft() }
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !knowledgeReadyForDisposition {
                        Text("The accepted implementation must enter the knowledge review lane before a durable note proposal can be created.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Writable scope", selection: $targetScopeID) {
                        Text("Choose a writable scope").tag(String?.none)
                        ForEach(writableScopes) { scope in
                            Text(scope.path).tag(Optional(scope.id))
                        }
                    }
                    .labelsHidden()
                    if writableScopes.isEmpty {
                        Text("Add a writable Obsidian scope in Knowledge before proposing an edit.")
                            .font(.caption)
                            .foregroundStyle(KanameColor.warning)
                    }
                    TextField("Vault-relative Markdown note path", text: $targetPath)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Vault-relative target note path")
                    Text("The exact note must already exist inside the selected writable scope. No write occurs during inspection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Inspect & seed editable draft", systemImage: "doc.text.magnifyingglass") {
                        knowledge.prepareCodingDraft(
                            model: model,
                            threadID: thread.id,
                            path: targetPath,
                            scopePath: selectedScope?.path ?? "",
                            candidates: lane.candidates
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!knowledgeReadyForDisposition || knowledge.isBusy || selectedScope == nil || targetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .panelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed coding knowledge edit")
    }

    private func statusSection(_ lane: DesktopCodingKnowledgeLane) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conflicts/status").font(.headline)
            LabeledContent("Disposition", value: lane.disposition.label)
            if let acceptedWorktreeID = lane.acceptedWorktreeID {
                LabeledContent("Accepted worktree", value: acceptedWorktreeID)
            }
            if let reason = lane.dispositionReason, !reason.isEmpty {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if let activeWrite, let currentDigest = activeWrite.currentDigest {
                LabeledContent("Current digest", value: currentDigest)
            }
            if let document = model.snapshot.operations.knowledgeDocuments.first(where: {
                $0.path == activeWrite?.targetPath
            }) {
                LabeledContent("Persisted digest", value: document.digest)
                if let conflictDigest = document.conflictDigest {
                    LabeledContent("Conflict digest", value: conflictDigest)
                }
            }
            if lane.disposition == .reconciled || lane.disposition == .waived {
                Label(
                    lane.disposition == .reconciled ? "Durable update reconciled" : "No durable update recorded with an explicit reason",
                    systemImage: "checkmark.seal"
                )
                .foregroundStyle(KanameColor.success)
            } else {
                Divider()
                Text("No durable update").font(.subheadline.weight(.semibold))
                TextField("Reason required", text: $waiverReason, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Reason for no durable knowledge update")
                Button("Record no durable update", systemImage: "arrow.uturn.left") {
                    let reason = waiverReason.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !reason.isEmpty else { return }
                    if model.waiveCodingKnowledge(threadID: thread.id, reason: reason) {
                        waiverReason = ""
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!knowledgeReadyForDisposition || waiverReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("This records an explicit reason and completes the knowledge lane without writing a note")
            }
        }
        .panelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coding knowledge conflicts and status")
    }
}

struct DesktopKnowledgeView: View {
    @ObservedObject var model: DesktopAppModel
    let searchRequest: DesktopSearchNavigationRequest?
    @StateObject private var knowledge = DesktopKnowledgeViewModel()
    @State private var selectedScopeID: String?
    @State private var selectedPath: String?
    @State private var searchText = ""
    @State private var editing = false
    @State private var showsScopeSheet = false

    private var selectedScope: DesktopVaultScopeRecord? {
        model.snapshot.operations.vaultScopes.first { $0.id == selectedScopeID }
    }

    private var activeWrite: DesktopKnowledgeWriteRecord? {
        knowledge.activeWriteID.flatMap { id in model.snapshot.operations.knowledgeWrites.first { $0.id == id } }
    }

    private var activeApproval: DesktopApprovalRecord? {
        activeWrite?.approvalID.flatMap { id in model.snapshot.operations.approvals.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader(
                title: "Obsidian & Knowledge",
                detail: "Native notes with explicit scope, provenance, freshness, and conflict-safe writes",
                symbol: DesktopDestination.knowledge.symbol
            ) {
                ControlGroup {
                    Button("Add scope", systemImage: "folder.badge.plus") { showsScopeSheet = true }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        if let selectedPath { knowledge.inspect(model: model, path: selectedPath) }
                    }
                    .disabled(selectedPath == nil || knowledge.isBusy)
                }
                .controlGroupStyle(.navigation)
            }
            .padding(24)

            Divider()

            HSplitView {
                knowledgeSidebar
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
                noteWorkspace
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(KanameColor.canvas)
        .onAppear {
            knowledge.seedDefaultScope(model: model)
            if !applySearchRequest() {
                if selectedScopeID == nil { selectedScopeID = model.snapshot.operations.vaultScopes.first?.id }
                if selectedPath == nil, let path = selectedScope?.path, path.hasSuffix(".md") {
                    selectedPath = path
                    knowledge.inspect(model: model, path: path)
                }
            }
        }
        .onChange(of: searchRequest?.id) { _ in
            _ = applySearchRequest()
        }
        .sheet(isPresented: $showsScopeSheet) {
            NewVaultScopeSheet(model: model) { id in
                selectedScopeID = id
            }
        }
    }

    @discardableResult
    private func applySearchRequest() -> Bool {
        guard let searchRequest,
              searchRequest.target.kind == .knowledgeDocument,
              model.snapshot.operations.knowledgeDocuments.contains(where: {
                  $0.path == searchRequest.target.itemID
              }) else { return false }
        let path = searchRequest.target.itemID
        if let scope = model.snapshot.operations.vaultScopes
            .filter({ path == $0.path || path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }) {
            selectedScopeID = scope.id
        }
        selectedPath = path
        knowledge.inspect(model: model, path: path)
        return true
    }

    private var knowledgeSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Vault scope").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let selectedScope {
                    Label(selectedScope.canWrite ? "Read & write" : "Read only", systemImage: selectedScope.canWrite ? "pencil.and.outline" : "eye")
                        .font(.caption2)
                        .foregroundStyle(selectedScope.canWrite ? KanameColor.warning : KanameColor.accent)
                }
            }
            Picker("Vault scope", selection: $selectedScopeID) {
                Text("Choose a scope").tag(String?.none)
                ForEach(model.snapshot.operations.vaultScopes) { scope in
                    Text(scope.path).tag(Optional(scope.id))
                }
            }
            .labelsHidden()
            .onChange(of: selectedScopeID) { _ in
                knowledge.clearSearch()
                if let path = selectedScope?.path, path.hasSuffix(".md") {
                    selectedPath = path
                    knowledge.inspect(model: model, path: path)
                }
            }

            HStack(spacing: 8) {
                TextField("Search this scope", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button("Search", systemImage: "magnifyingglass") { runSearch() }
                    .labelStyle(.iconOnly)
                    .disabled(selectedScope == nil || searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if knowledge.searchResults.isEmpty {
                Text(selectedScope?.path.hasSuffix(".md") == true
                     ? "This is an exact-note scope. Add a folder scope to search neighboring notes."
                     : "Search results stay inside the selected scope.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(knowledge.searchResults) { result in
                            Button {
                                selectedPath = result.path
                                knowledge.inspect(model: model, path: result.path)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(URL(fileURLWithPath: result.path).deletingPathExtension().lastPathComponent)
                                        .font(.subheadline.weight(.semibold))
                                    Text(result.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    if !result.context.isEmpty {
                                        Text(result.context).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .background(selectedPath == result.path ? KanameColor.raised : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            DisclosureGroup("Context sources") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.snapshot.domains.knowledgeSources) { source in
                        HStack(alignment: .top) {
                            Image(systemName: source.kind.symbol).foregroundStyle(source.kind.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).font(.caption.weight(.semibold))
                                Text("\(source.kind.label) · \(source.scope)")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    if !model.snapshot.domains.knowledgeSources.contains(where: { $0.kind == .lode }) {
                        Text("Lode is not connected; no Lode content is silently assumed current.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }

            if !model.snapshot.operations.capabilityUpdates.isEmpty {
                DisclosureGroup("Capability updates") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.snapshot.operations.capabilityUpdates) { update in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(update.source).font(.caption.weight(.semibold))
                                Text("\(update.previousRevision) → \(update.proposedRevision)").font(.caption2)
                                Text(update.changeSummary).font(.caption2).foregroundStyle(.secondary)
                                if update.state == .proposed {
                                    HStack {
                                        Button("Accept") { model.reviewCapabilityUpdate(id: update.id, accepted: true) }
                                        Button("Reject") { model.reviewCapabilityUpdate(id: update.id, accepted: false) }
                                    }
                                    .controlSize(.small)
                                } else {
                                    KanameStatusBadge(
                                        KanameDesktopStatusPresentation.action(update.state),
                                        density: .compact
                                    )
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Spacer(minLength: 8)
            if let selectedScope {
                Button("Remove scope", systemImage: "minus.circle", role: .destructive) {
                    model.removeVaultScope(id: selectedScope.id)
                    selectedScopeID = model.snapshot.operations.vaultScopes.first?.id
                }
                .font(.caption)
            }
        }
        .padding(18)
        .background(KanameColor.surface)
    }

    @ViewBuilder
    private var noteWorkspace: some View {
        if knowledge.isBusy, knowledge.document == nil {
            VStack(spacing: 12) { ProgressView(); Text("Reading selected note…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let document = knowledge.document {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: document.path).deletingPathExtension().lastPathComponent)
                                .font(.title2.weight(.bold))
                            Text(document.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Picker("Mode", selection: $editing) {
                            Text("Read").tag(false)
                            Text("Edit").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }

                    if editing {
                        TextEditor(text: $knowledge.draft)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 440)
                            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Markdown editor for \(document.path)")
                    } else {
                        NativeObsidianMarkdown(content: knowledge.draft)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
                    }

                    knowledgeMetadata(document: document)

                    if editing {
                        HStack {
                            Button("Review changes", systemImage: "doc.text.magnifyingglass") {
                                knowledge.reviewDraft(model: model)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(knowledge.isBusy || selectedScope?.canWrite != true)
                            Button("Reset draft", systemImage: "arrow.uturn.backward") { knowledge.resetDraft() }
                            Spacer()
                            if selectedScope?.canWrite != true {
                                Label("This scope is read only", systemImage: "lock.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let diff = knowledge.diff {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(diff.summary, systemImage: "plusminus")
                                    .font(.headline)
                                Spacer()
                                if let activeWrite {
                                    KanameStatusBadge(
                                        KanameDesktopStatusPresentation.action(activeWrite.state),
                                        density: .compact
                                    )
                                }
                            }
                            ScrollView(.horizontal) {
                                Text(diff.unifiedDiff).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            HStack {
                                if activeApproval == nil {
                                    Button("Request write approval", systemImage: "checkmark.shield") {
                                        knowledge.requestApproval(model: model)
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else if activeApproval?.state == .approved {
                                    Button("Apply approved edit", systemImage: "square.and.arrow.down") {
                                        knowledge.applyApprovedDraft(model: model)
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else {
                                    Label(activeApproval?.state == .rejected ? "Write rejected" : "Waiting in Inbox", systemImage: "tray.full")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .panelStyle()
                    }

                    if let message = knowledge.message {
                        BoundaryCallout(
                            title: activeWrite?.state == .failed ? "Conflict or write failure" : "Knowledge status",
                            detail: message
                        )
                    }
                }
                .padding(24)
            }
        } else {
            EmptyPanel(
                symbol: "note.text",
                title: "Choose a scoped note",
                detail: "Kaname reads only the vault paths you add. Folder scopes enable search; write access is a separate choice."
            )
            .padding(24)
        }
    }

    private func knowledgeMetadata(document: ObsidianDocumentSnapshot) -> some View {
        let record = model.snapshot.operations.knowledgeDocuments.first { $0.path == document.path }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Revision \(document.digest.prefix(12))", systemImage: "checkmark.seal")
                Spacer()
                if let record { RelativeTime(unixMillis: record.lastReadAtUnixMillis) }
            }
            .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("Use as").font(.caption.weight(.semibold))
                Picker("Project context role", selection: Binding(
                    get: { record?.role },
                    set: { model.classifyKnowledgeDocument(path: document.path, projectID: "project-kaname", role: $0) }
                )) {
                    Text("Unclassified").tag(DesktopKnowledgeDocumentRecord.Role?.none)
                    ForEach(DesktopKnowledgeDocumentRecord.Role.allCases, id: \.self) { role in
                        Text(role.label).tag(Optional(role))
                    }
                }
                .labelsHidden()
                Spacer()
                Text(record?.provenance ?? "Local Obsidian vault").font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("Context & provenance") {
                VStack(alignment: .leading, spacing: 9) {
                    MetadataTokens(title: "Properties", values: document.properties.map { "\($0.key): \($0.value)" }.sorted())
                    MetadataTokens(title: "Wikilinks", values: document.wikilinks)
                    MetadataTokens(title: "Backlinks", values: document.backlinks)
                    MetadataTokens(title: "Attachments", values: document.attachments)
                    MetadataTokens(title: "Attributed sources", values: record?.sourceURLs ?? [])
                }
                .padding(.top, 8)
            }
        }
        .panelStyle()
    }

    private func runSearch() {
        guard let selectedScope else { return }
        knowledge.search(model: model, query: searchText, scope: selectedScope)
    }
}

private struct NativeObsidianMarkdown: View {
    let content: String

    private var bodyLines: [String] {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first == "---",
              let closing = lines.dropFirst().firstIndex(of: "---") else { return lines }
        return Array(lines.suffix(from: lines.index(after: closing)))
    }

    private enum Block {
        case line(String)
        case code(String)
        case table(header: [String], rows: [[String]])
    }

    /// Groups fenced code and pipe tables into blocks; every other line renders on its own.
    private var blocks: [Block] {
        var blocks: [Block] = []
        var code: [String]?
        var table: [[String]] = []
        func flushTable() {
            guard !table.isEmpty else { return }
            let header = table[0]
            let rows = table.dropFirst().filter { row in
                !row.allSatisfy { cell in cell.trimmingCharacters(in: .whitespaces).allSatisfy { ":-".contains($0) } }
            }
            blocks.append(.table(header: header, rows: Array(rows)))
            table = []
        }
        for line in bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushTable()
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                table.append(
                    trimmed.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                )
                continue
            }
            flushTable()
            blocks.append(.line(line))
        }
        flushTable()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .line(line):
                    rendered(line)
                case let .code(text):
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: 8))
                case let .table(header, rows):
                    tableView(header: header, rows: rows)
                }
            }
        }
    }

    private func tableView(header: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(inline(cell)).font(.caption.weight(.semibold))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell)).font(.caption)
                        }
                    }
                }
            }
            .padding(10)
            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func rendered(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 5)
        } else if let range = trimmed.range(of: #"^(\d+[.)]|[-*+])\s+\[([ xX])\]\s+"#, options: .regularExpression) {
            let checked = trimmed[range].contains("x") || trimmed[range].contains("X")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? KanameColor.success : .secondary)
                Text(inline(String(trimmed[range.upperBound...])))
                    .strikethrough(checked, color: .secondary)
            }
        } else if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(trimmed[range]).trimmingCharacters(in: .whitespaces))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(KanameColor.accent)
                Text(inline(String(trimmed[range.upperBound...])))
            }
        } else if trimmed.hasPrefix("#") {
            let level = min(trimmed.prefix(while: { $0 == "#" }).count, 6)
            Text(inline(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                .font(headingFont(level: level))
                .padding(.top, level == 1 ? 7 : 3)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(KanameColor.accent)
                Text(inline(String(trimmed.dropFirst(2))))
            }
        } else if trimmed.hasPrefix("> [!") {
            Label(calloutText(trimmed), systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KanameColor.accent)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: 9))
        } else if trimmed.hasPrefix(">") {
            Text(inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                .italic()
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(KanameColor.accent).frame(width: 3) }
        } else {
            Text(inline(trimmed)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ value: String) -> AttributedString {
        let readable = readableWikilinks(in: value)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: readable, options: options)) ?? AttributedString(readable)
    }

    private func readableWikilinks(in value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"\[\[([^\]|#]+)(?:[|#]([^\]]+))?\]\]"#) else {
            return value
        }
        var result = value
        let sourceRange = NSRange(value.startIndex..., in: value)
        for match in expression.matches(in: value, range: sourceRange).reversed() {
            guard let whole = Range(match.range(at: 0), in: result),
                  let targetRange = Range(match.range(at: 1), in: value) else { continue }
            let alias = match.range(at: 2).location == NSNotFound
                ? nil
                : Range(match.range(at: 2), in: value).map { String(value[$0]) }
            result.replaceSubrange(whole, with: alias ?? String(value[targetRange]))
        }
        return result
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        default: .headline
        }
    }

    private func calloutText(_ line: String) -> String {
        guard let close = line.firstIndex(of: "]") else { return line }
        let title = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Note" : title
    }
}

private struct MetadataTokens: View {
    let title: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            Text(values.isEmpty ? "None" : values.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

private struct NewVaultScopeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    let onCreate: (String) -> Void
    @State private var path = ""
    @State private var canWrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Obsidian scope").font(.title2.weight(.bold))
            Text("Choose a vault-relative note or folder. Kaname never expands this boundary automatically.")
                .foregroundStyle(.secondary)
            TextField("Projects/Example or Projects/Example/Overview.md", text: $path)
                .textFieldStyle(.roundedBorder)
            Toggle("Allow proposing writes inside this scope", isOn: $canWrite)
            if canWrite {
                Label("Every write still needs an exact diff approval and current-revision check.", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(KanameColor.warning)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add scope") {
                    if let id = model.addVaultScope(path: path, sourceID: nil, canWrite: canWrite) {
                        onCreate(id)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 520)
    }
}
