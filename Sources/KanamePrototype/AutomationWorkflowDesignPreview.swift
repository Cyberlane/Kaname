import KanameDesktop
import KanameLocalCore
import KanameProtocol
import KanamePrototypeUI
import KanameWorkflowHost
import SwiftUI
import KanameDesignSystem

private struct AutomationWorkflowStarterTemplate: Identifiable {
    let id: String
    let title: String
    let summary: String
    let symbol: String
    let tint: Color
    let triggerKinds: [DesktopWorkflowTriggerKind]
    let steps: [DesktopWorkflowStepDefinition]

    var canvasPositions: [DesktopWorkflowCanvasNodePosition] {
        steps.enumerated().map { index, step in
            .init(
                stepID: step.id,
                x: Double(index) * 210 + 30,
                y: 40
            )
        }
    }

    static var patterns: [Self] {
        let complete = DesktopWorkflowStepDefinition(id: "complete", name: "Complete", kind: .complete)
        return [
            .init(
                id: "email-feedback",
                title: "Email feedback loop",
                summary: "Keep one durable conversation across replies and human review.",
                symbol: "envelope.arrow.triangle.branch",
                tint: KanameColor.accent,
                triggerKinds: [.email],
                steps: [
                    .init(
                        id: "receive", name: "Receive email", kind: .classifyEvent,
                        transitions: [.init(outcome: .always, targetStepID: "correlate")]
                    ),
                    .init(
                        id: "correlate", name: "Correlate conversation", kind: .correlateWork,
                        transitions: [.init(outcome: .always, targetStepID: "wait")]
                    ),
                    .init(
                        id: "wait", name: "Wait for reply", kind: .waitForEmail,
                        transitions: [
                            .init(outcome: .succeeded, targetStepID: "review"),
                            .init(outcome: .timedOut, targetStepID: "complete"),
                        ],
                        waitContract: .init(connectorID: "kaname.mail", source: "mail")
                    ),
                    .init(
                        id: "review", name: "Review reply", kind: .humanReview,
                        transitions: [
                            .init(outcome: .approved, targetStepID: "complete"),
                            .init(outcome: .rejected, targetStepID: "complete"),
                        ],
                        reviewContract: makeWorkflowStudioReviewContract(title: "Review reply")
                    ),
                    complete,
                ]
            ),
            .init(
                id: "classify-route",
                title: "Classify and route",
                summary: "Choose typed matched and fallback paths from one decision.",
                symbol: "arrow.triangle.branch",
                tint: KanameColor.warning,
                triggerKinds: [.manual],
                steps: [
                    .init(
                        id: "route", name: "Classify and route", kind: .branch,
                        transitions: [
                            .init(
                                outcome: .matched,
                                targetStepID: "review",
                                predicates: [.init(pointer: "/matched", operation: .equals, value: "true")]
                            ),
                            .init(outcome: .notMatched, targetStepID: "complete"),
                        ]
                    ),
                    .init(
                        id: "review", name: "Review match", kind: .humanReview,
                        transitions: [
                            .init(outcome: .approved, targetStepID: "complete"),
                            .init(outcome: .rejected, targetStepID: "complete"),
                        ],
                        reviewContract: makeWorkflowStudioReviewContract(title: "Review match")
                    ),
                    complete,
                ]
            ),
            .init(
                id: "parallel-review",
                title: "Parallel review",
                summary: "Run a bounded collection concurrently, then review the aggregate.",
                symbol: "arrow.triangle.2.circlepath",
                tint: KanameColor.blocked,
                triggerKinds: [.manual],
                steps: [
                    .init(
                        id: "items", name: "Run independent checks", kind: .forEach,
                        transitions: [
                            .init(outcome: .succeeded, targetStepID: "review"),
                            .init(outcome: .failed, targetStepID: "complete"),
                        ],
                        batchPolicy: .init(maximumItems: 100, maximumConcurrency: 4)
                    ),
                    .init(
                        id: "review", name: "Review aggregate", kind: .humanReview,
                        transitions: [
                            .init(outcome: .approved, targetStepID: "complete"),
                            .init(outcome: .rejected, targetStepID: "complete"),
                        ],
                        reviewContract: makeWorkflowStudioReviewContract(title: "Review aggregate")
                    ),
                    complete,
                ]
            ),
            .init(
                id: "approval-gate",
                title: "Approval gate",
                summary: "Place an explicit approval barrier before adding a reviewed effect.",
                symbol: "checkmark.shield",
                tint: KanameColor.success,
                triggerKinds: [.manual],
                steps: [
                    .init(
                        id: "prepare", name: "Prepare proposal", kind: .classifyEvent,
                        transitions: [.init(outcome: .always, targetStepID: "approval")]
                    ),
                    .init(
                        id: "approval", name: "Request approval", kind: .requestApproval,
                        transitions: [.init(outcome: .approved, targetStepID: "complete")]
                    ),
                    complete,
                ]
            ),
            .init(
                id: "batch-processing",
                title: "Batch processing",
                summary: "Process a bounded collection with controlled concurrency and aggregation.",
                symbol: "square.stack.3d.up",
                tint: KanameColor.accent,
                triggerKinds: [.manual],
                steps: [
                    .init(
                        id: "prepare", name: "Prepare items", kind: .classifyEvent,
                        transitions: [.init(outcome: .always, targetStepID: "items")]
                    ),
                    .init(
                        id: "items", name: "Process items", kind: .forEach,
                        transitions: [
                            .init(outcome: .succeeded, targetStepID: "complete"),
                            .init(outcome: .failed, targetStepID: "complete"),
                        ],
                        batchPolicy: .init(maximumItems: 100, maximumConcurrency: 4)
                    ),
                    complete,
                ]
            ),
            .init(
                id: "blank",
                title: "Blank workflow",
                summary: "Start with one typed input node and a terminal node.",
                symbol: "plus.rectangle.on.rectangle",
                tint: Color.secondary,
                triggerKinds: [.manual],
                steps: [
                    .init(
                        id: "prepare", name: "Receive input", kind: .classifyEvent,
                        transitions: [.init(outcome: .always, targetStepID: "complete")]
                    ),
                    complete,
                ]
            ),
        ]
    }

}

struct AutomationWorkflowProductView: View {
    private enum Section: String, CaseIterable {
        case workflows = "Workflows"
        case builder = "Builder"
        case runs = "Run history"
        case components = "Components"
        case readiness = "Readiness"

        var symbol: String {
            switch self {
            case .workflows: "square.stack.3d.up"
            case .builder: "point.3.connected.trianglepath.dotted"
            case .runs: "clock.arrow.circlepath"
            case .components: "puzzlepiece.extension"
            case .readiness: "checkmark.seal"
            }
        }

        static func initial(arguments: [String]) -> Self {
            if arguments.contains("--desktop-automation-product-builder")
                || arguments.contains("--desktop-automation-product-new-workflow")
                || arguments.contains("--desktop-automation-product-studio") { return .builder }
            if arguments.contains("--desktop-automation-product-runs") { return .runs }
            if arguments.contains("--desktop-automation-product-readiness") { return .readiness }
            if arguments.contains("--desktop-automation-product-components")
                || arguments.contains("--desktop-automation-schedules") { return .components }
            return .workflows
        }
    }

    @ObservedObject var model: DesktopAppModel
    @ObservedObject var scheduler: DesktopAutomationSchedulerViewModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @StateObject private var mail = DesktopMailViewModel()
    @State private var section = Section.initial(arguments: CommandLine.arguments)
    @State private var selectedWorkflowID: String?
    @State private var studioDraftID: String?
    @State private var showsWorkflowStarter = CommandLine.arguments.contains("--desktop-automation-product-new-workflow")
    @State private var workflowStarterMessage: String?
    @State private var preparedStudioQualificationFixture = false
    @State private var manualRunDefinition: DesktopWorkflowDefinitionRecord?
    private let libraryRunner = LocalCoreRunner.bundled()
    @State private var installationToConfigure: DesktopWorkflowInstallationRecord?
    @State private var editingSchedule: DesktopAutomationRule?
    @State private var showsNewSchedule = false
    @State private var packageMessage: String?
    /// Compiler availability per legacy step for the revision on screen.
    @State private var nodeAvailability: [String: LocalCoreRunner.WorkflowNodeAvailabilityDecision] = [:]
    @State private var nodeAvailabilityRevisionID: String?

    private var definitions: [DesktopWorkflowDefinitionRecord] { model.workflowDefinitions }

    private var selectedDefinition: DesktopWorkflowDefinitionRecord? {
        definitions.first { $0.id == selectedWorkflowID } ?? definitions.first
    }

    private var selectedRevision: DesktopWorkflowRevisionRecord? {
        guard let selectedDefinition else { return nil }
        return model.snapshot.operations.workflows.revisions.first { $0.id == selectedDefinition.currentRevisionID }
    }

    private var workflowPresentations: [AutomationWorkflowPreview] {
        definitions.map { definition in
            let revision = model.snapshot.operations.workflows.revisions.first { $0.id == definition.currentRevisionID }
            let workItems = model.workflowWorkItems.filter { $0.workflowID == definition.id }
            let runIDs = Set(workItems.flatMap { item in model.workflowEpisodes(workItemID: item.id).flatMap { model.workflowRuns(episodeID: $0.id).map(\.id) } })
            let runs = model.snapshot.operations.workflows.runs.filter { runIDs.contains($0.id) }
            let readiness = model.workflowMigrationReadiness(workflowID: definition.id)
            let activeState = workItems.map(\.state)
            let state: AutomationPreviewState
            if readiness.blockedCount > 0 { state = .blocked }
            else if activeState.contains(where: { $0.needsAttention }) { state = .blocked }
            else if activeState.contains(.running) || runs.contains(where: { $0.state == .running }) { state = .running }
            else if activeState.contains(.waitingExternal) || runs.contains(where: { $0.state == .waiting }) { state = .waiting }
            else if definition.enabled { state = .complete }
            else { state = .planned }
            let trigger = definition.triggerKinds.map(\.label).joined(separator: " + ")
            let latestRun = runs.max { ($0.startedAtUnixMillis ?? 0) < ($1.startedAtUnixMillis ?? 0) }
            let installations = model.workflowInstallations(workflowID: definition.id)
            let progress = definition.enabled ? 4 : readiness.blockedCount == 0 ? 2 : 1
            return AutomationWorkflowPreview(
                id: definition.id,
                name: definition.name,
                summary: definition.source == "Kaname synthetic fixtures"
                    ? "Synthetic fixture · not operational · \(definition.summary)"
                    : definition.summary,
                symbol: definition.icon,
                progress: progress,
                state: state,
                version: revision?.version ?? "Unknown",
                trigger: trigger.isEmpty ? "Unconfigured" : trigger,
                lastRun: latestRun.map { $0.state.label } ?? "Never",
                retention: installations.isEmpty ? "Not configured" : "Per installation"
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader(
                title: "Automations",
                detail: "Design, test, run, and understand every repeatable workflow",
                symbol: "point.3.connected.trianglepath.dotted"
            ) {
                Label("Local workspace", systemImage: "lock.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if section == .workflows {
                    Button("New workflow", systemImage: "plus") { createWorkflow() }
                        .buttonStyle(.borderedProminent)
                } else if section == .components {
                    Button("Install package…", systemImage: "shippingbox") { installPackage() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Picker("Automations view", selection: $section) {
                ForEach(Section.allCases, id: \.self) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            Group {
                switch section {
                case .workflows:
                    workflowsPage
                case .builder:
                    builderPage
                case .runs:
                    AutomationLiveRunsView()
                case .components:
                    AutomationComponentsView(
                        model: model,
                        scheduler: scheduler,
                        packageMessage: packageMessage,
                        createSchedule: { showsNewSchedule = true },
                        editSchedule: { editingSchedule = $0 }
                    )
                case .readiness:
                    AutomationReadinessView(
                        model: model,
                        integrations: integrations,
                        selectedWorkflowID: $selectedWorkflowID,
                        configureInstallation: { installationToConfigure = $0 }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(KanameColor.canvas)
        .onAppear {
            if selectedWorkflowID == nil { selectedWorkflowID = definitions.first?.id }
            prepareStudioQualificationFixtureIfRequested()
        }
        .onChange(of: definitions.map(\.id)) { ids in
            if selectedWorkflowID == nil || !ids.contains(selectedWorkflowID ?? "") {
                selectedWorkflowID = ids.first
            }
        }
        .sheet(item: $manualRunDefinition) { definition in
            WorkflowManualRunSheet(
                definition: definition,
                revision: model.snapshot.operations.workflows.revisions.first { $0.id == definition.currentRevisionID }
            ) { title, request, input in
                mail.runWorkflowManually(
                    model: model, workflowID: definition.id,
                    title: title, request: request, input: input
                )
            }
        }
        .sheet(item: $installationToConfigure) { installation in
            WorkflowInstallationSetupSheet(
                model: model,
                installation: installation,
                accounts: integrations.googleAccounts
            )
        }
        .sheet(isPresented: $showsNewSchedule) { NewAutomationSheet(model: model) }
        .sheet(item: $editingSchedule) { NewAutomationSheet(model: model, editing: $0) }
    }

    @ViewBuilder
    private var workflowsPage: some View {
        if workflowPresentations.isEmpty {
            EmptyPanel(
                symbol: "square.stack.3d.up",
                title: "No workflows installed",
                detail: "Create a workflow or install a reviewed package. New definitions remain disabled until Readiness is complete."
            )
            .padding(24)
        } else {
            ScrollView {
                AutomationPipelinePreview(
                    workflows: workflowPresentations,
                    selectedWorkflowID: Binding(
                        get: { selectedWorkflowID ?? workflowPresentations[0].id },
                        set: { selectedWorkflowID = $0 }
                    ),
                    openBuilder: { section = .builder },
                    openRunHistory: { section = .runs },
                    createWorkflow: createWorkflow
                )
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private var builderPage: some View {
        if showsWorkflowStarter {
            ScrollView {
                AutomationNewWorkflowDesign(
                    workflows: definitions,
                    message: workflowStarterMessage,
                    onUseTemplate: createWorkflow(from:),
                    onDuplicate: duplicateWorkflow(_:),
                    onImportSource: importWorkflowSource(_:),
                    onCancel: cancelWorkflowStarter
                )
                .padding(20)
            }
        } else if let studioDraftID {
            WorkflowStudioSheet(
                model: model,
                draftID: studioDraftID,
                presentation: .embedded,
                onCancel: {
                    self.studioDraftID = nil
                    section = .workflows
                }
            ) { workflowID in
                selectedWorkflowID = workflowID
                self.studioDraftID = nil
                packageMessage = "Published \(workflowID) disabled. Review Readiness before enabling it."
            }
            .id(studioDraftID)
        } else if let definition = selectedDefinition, let revision = selectedRevision,
           let workflow = workflowPresentations.first(where: { $0.id == definition.id }) {
            ScrollView {
                AutomationCanvasPreview(
                    workflow: workflow,
                    graph: AutomationCanvasGraph.live(
                        revision: revision,
                        availability: nodeAvailabilityRevisionID == revision.id ? nodeAvailability : [:]
                    ),
                    revisions: model.snapshot.operations.workflows.revisions
                        .filter { $0.workflowID == definition.id }
                        .sorted { $0.installedAtUnixMillis > $1.installedAtUnixMillis },
                    sourceLines: workflowSourceLines(definition.id),
                    edit: { editWorkflow(definition) },
                    run: definition.triggerKinds.contains(.manual) && definition.enabled
                        ? { manualRunDefinition = definition }
                        : nil,
                    publish: libraryRunner == nil ? nil : { publishToLibrary(definition, revision: revision) }
                )
                .padding(20)
            }
            .task(id: revision.id) { await evaluateNodeAvailability(definition, revision: revision) }
        } else {
            EmptyPanel(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "No workflow selected",
                detail: "Create a workflow or install a reviewed package, then open it from Workflows."
            )
            .padding(24)
        }
    }

    private func createWorkflow() {
        workflowStarterMessage = nil
        studioDraftID = nil
        showsWorkflowStarter = true
        section = .builder
    }

    private func createWorkflow(from template: AutomationWorkflowStarterTemplate) {
        guard let draftID = model.createWorkflowStudioDraft(
            name: template.title,
            summary: template.summary,
            icon: template.symbol
        ), let draft = model.snapshot.operations.workflows.studioDrafts.first(where: { $0.id == draftID }) else {
            workflowStarterMessage = "Kaname could not create the workflow draft."
            return
        }
        guard model.updateWorkflowStudioDraft(
            id: draftID,
            triggerKinds: template.triggerKinds,
            steps: template.steps,
            permissions: .init(),
            subflows: [],
            canvasPositions: template.canvasPositions,
            manifestMetadata: draft.manifestMetadata
        ), model.snapshot.operations.workflows.studioDrafts
            .first(where: { $0.id == draftID })?.validationSummary == nil else {
            _ = model.discardWorkflowStudioDraft(id: draftID)
            workflowStarterMessage = "The selected pattern could not be converted into a valid draft."
            return
        }
        workflowStarterMessage = nil
        studioDraftID = draftID
        showsWorkflowStarter = false
    }

    /// Asks the Rust compiler which of this revision's steps would execute as
    /// configured. Converts through the same importer that publishing uses, so
    /// the Builder shows the decision the library would record.
    private func evaluateNodeAvailability(
        _ definition: DesktopWorkflowDefinitionRecord,
        revision: DesktopWorkflowRevisionRecord
    ) async {
        guard let runner = libraryRunner,
              let imported = try? DesktopWorkflowLegacyImporter.importSource(.init(definition: definition, revision: revision))
        else { return }
        let legacyIDByNodeID = Dictionary(
            imported.nodeIDByLegacyStepID.map { ($0.value, $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let queries = imported.workflow.graph.nodes.compactMap { node -> LocalCoreRunner.WorkflowNodeAvailabilityQuery? in
            guard legacyIDByNodeID[node.id] != nil,
                  let configData = try? encoder.encode(node.config),
                  let configJSON = String(data: configData, encoding: .utf8) else { return nil }
            return .init(nodeID: node.id, type: node.type, configJSON: configJSON)
        }
        guard let decisions = try? await runner.evaluateWorkflowNodeAvailability(queries) else { return }
        var byLegacyID: [String: LocalCoreRunner.WorkflowNodeAvailabilityDecision] = [:]
        for decision in decisions {
            if let legacyID = legacyIDByNodeID[decision.nodeID] { byLegacyID[legacyID] = decision }
        }
        nodeAvailability = byLegacyID
        nodeAvailabilityRevisionID = revision.id
    }

    /// Converts a Builder workflow to the durable v1 graph and publishes it as
    /// an active revision in the Rust library. Lossy conversions are reported
    /// and not published.
    private func publishToLibrary(_ definition: DesktopWorkflowDefinitionRecord, revision: DesktopWorkflowRevisionRecord) {
        guard let runner = libraryRunner else { return }
        let imported: DesktopWorkflowLegacyImportResult
        do {
            imported = try DesktopWorkflowLegacyImporter.importSource(.init(definition: definition, revision: revision))
        } catch {
            packageMessage = "Could not convert \(definition.name): \(error.localizedDescription)"
            return
        }
        guard imported.isLossless else {
            let losses = imported.losses.map(\.summary).joined(separator: "; ")
            packageMessage = "\(definition.name) cannot be published yet. The durable graph would lose: \(losses)"
            return
        }
        Task {
            do {
                let result = try await runner.publishWorkflow(
                    workflowID: imported.workflow.workflowId,
                    packageID: imported.workflow.packageId,
                    name: imported.workflow.name,
                    summary: imported.workflow.summary,
                    workflowJSON: imported.canonicalSource,
                    activate: true
                )
                packageMessage = "\(definition.name) published to the durable library as revision \(result.revisionID.suffix(8)) (\(result.executionSupport))\(result.activated ? ", active" : ""). Run it from Run history."
            } catch {
                packageMessage = "Publishing \(definition.name) failed: \(error.localizedDescription)"
            }
        }
    }

    private func duplicateWorkflow(_ definition: DesktopWorkflowDefinitionRecord) {
        guard let draftID = model.forkWorkflowRevisionToStudio(revisionID: definition.currentRevisionID) else {
            workflowStarterMessage = "Kaname could not duplicate the selected published revision."
            return
        }
        workflowStarterMessage = nil
        studioDraftID = draftID
        showsWorkflowStarter = false
    }

    private func importWorkflowSource(_ source: String) -> Bool {
        guard let draftID = model.createWorkflowStudioDraft(
            name: "Imported workflow",
            summary: "A workflow authored from canonical source."
        ) else {
            workflowStarterMessage = "Kaname could not create an import draft."
            return false
        }
        guard model.replaceWorkflowStudioDraftSource(id: draftID, source: source) else {
            _ = model.discardWorkflowStudioDraft(id: draftID)
            workflowStarterMessage = "The source is invalid, unsafe, oversized, or refers to unavailable capabilities."
            return false
        }
        workflowStarterMessage = nil
        studioDraftID = draftID
        showsWorkflowStarter = false
        return true
    }

    private func cancelWorkflowStarter() {
        showsWorkflowStarter = false
        workflowStarterMessage = nil
        section = .workflows
    }

    private func prepareStudioQualificationFixtureIfRequested() {
        guard CommandLine.arguments.contains("--desktop-automation-product-studio"),
              !preparedStudioQualificationFixture else { return }
        preparedStudioQualificationFixture = true
        createWorkflow(from: AutomationWorkflowStarterTemplate.patterns[0])
    }

    private func editWorkflow(_ definition: DesktopWorkflowDefinitionRecord) {
        showsWorkflowStarter = false
        studioDraftID = model.editWorkflowRevisionInStudio(revisionID: definition.currentRevisionID)
    }

    private func installPackage() {
        do {
            packageMessage = try DesktopWorkflowTransferUI.installPackage(model: model)
        } catch {
            packageMessage = error.localizedDescription
        }
    }

    private func workflowSourceLines(_ workflowID: String) -> [String] {
        guard let canonical = try? model.exportWorkflowPackage(workflowID: workflowID),
              let object = try? JSONSerialization.jsonObject(with: canonical),
              let formatted = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let source = String(data: formatted, encoding: .utf8) else { return [] }
        return source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

/// Run history reads the durable Rust workflow projection and nothing else. The
/// in-memory desktop snapshot is a design-time preview of workflow structure,
/// not run evidence, so it is deliberately not offered as a second timeline
/// here: a run either has durable evidence or its absence is stated outright.
private struct AutomationLiveRunsView: View {
    private let runner = LocalCoreRunner.bundled()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Run history").font(.title3.weight(.bold))
                    Text("Every run below is replayed from the durable Rust projection and stays pinned to the exact workflow revision it ran.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label("Durable projection", systemImage: "cylinder.split.1x2")
                    .font(.caption).foregroundStyle(.secondary)
                Label("Read-only evidence", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let runner {
                ScrollView { DesktopDurableWorkflowRunsView(runner: runner) }
            } else {
                EmptyPanel(
                    symbol: "externaldrive.badge.questionmark",
                    title: "Durable run history unavailable",
                    detail: "The local core service that owns the durable workflow projection is not reachable, so no run evidence can be read. Nothing is shown in its place, because the design-time workflow snapshot is not a record of what ran."
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AutomationComponentsView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var scheduler: DesktopAutomationSchedulerViewModel
    let packageMessage: String?
    let createSchedule: () -> Void
    let editSchedule: (DesktopAutomationRule) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Component library").font(.title3.weight(.bold))
                        Text("Reusable triggers, capabilities, connectors, renderers, and version-pinned subflows.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("\(componentCount) installed", systemImage: "puzzlepiece.extension.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(KanameColor.accent)
                }
                if let packageMessage {
                    BoundaryCallout(title: "Package operation", detail: packageMessage)
                }
                componentGuide
                schedules
                componentSection(
                    title: "Capabilities",
                    detail: "Deterministic processing and schema-constrained model or tool work",
                    symbol: "cpu",
                    empty: "No capabilities installed"
                ) {
                    ForEach(model.workflowCapabilityInstallations) { capability in
                        componentRow(
                            title: capability.name,
                            detail: "\(capability.capabilityID) · \(capability.runtime.rawValue)",
                            version: capability.version,
                            ready: capability.enabled && capability.lastTestPassed,
                            status: capability.enabled ? (capability.lastTestPassed ? "Enabled · tested" : "Enabled · test required") : "Disabled"
                        )
                    }
                }
                componentSection(
                    title: "Trusted connectors",
                    detail: "Credentialed network effects remain outside ordinary workflow capabilities",
                    symbol: "network.badge.shield.half.filled",
                    empty: "No trusted connectors installed"
                ) {
                    ForEach(model.snapshot.operations.workflows.connectorInstallations) { connector in
                        componentRow(
                            title: connector.name,
                            detail: connector.effectKinds.joined(separator: " · "),
                            version: connector.version,
                            ready: connector.enabled && connector.qualified,
                            status: connector.enabled ? (connector.qualified ? "Enabled · qualified" : "Qualification required") : "Disabled"
                        )
                    }
                }
                componentSection(
                    title: "Renderers",
                    detail: "Preview, recalculation, and range-selection adapters",
                    symbol: "doc.richtext",
                    empty: "No renderers installed"
                ) {
                    ForEach(model.snapshot.operations.workflows.rendererInstallations) { renderer in
                        componentRow(
                            title: renderer.name,
                            detail: renderer.mediaTypes.joined(separator: " · "),
                            version: renderer.version,
                            ready: renderer.enabled && renderer.qualified,
                            status: renderer.enabled ? (renderer.qualified ? "Enabled · qualified" : "Qualification required") : "Disabled"
                        )
                    }
                }
                componentSection(
                    title: "Reusable subflows",
                    detail: "Typed graph fragments pinned to an exact version",
                    symbol: "square.stack.3d.up",
                    empty: "No reusable subflows installed"
                ) {
                    ForEach(model.snapshot.operations.workflows.subflows) { subflow in
                        componentRow(
                            title: subflow.name,
                            detail: "\(subflow.steps.count) nodes · \(subflow.summary)",
                            version: subflow.version,
                            ready: subflow.enabled,
                            status: subflow.enabled ? "Available" : "Disabled"
                        )
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var componentCount: Int {
        model.workflowCapabilityInstallations.count
            + model.snapshot.operations.workflows.connectorInstallations.count
            + model.snapshot.operations.workflows.rendererInstallations.count
            + model.snapshot.operations.workflows.subflows.count
    }

    private var componentGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label("How components work together", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Text("A workflow coordinates small, versioned building blocks. Each component has one bounded job, so data handling, credentials, presentation, and reusable orchestration stay independently reviewable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                componentGuideCard(
                    title: "Capabilities",
                    symbol: "cpu",
                    detail: "Transform, validate, or interpret typed data. They do not receive ambient credentials or effect authority."
                )
                componentGuideCard(
                    title: "Trusted connectors",
                    symbol: "network.badge.shield.half.filled",
                    detail: "Own authenticated provider access and remote effects, with explicit qualification and authority checks."
                )
                componentGuideCard(
                    title: "Renderers",
                    symbol: "doc.richtext",
                    detail: "Turn artifacts into inspectable previews or recalculated output without changing the workflow definition."
                )
                componentGuideCard(
                    title: "Reusable subflows",
                    symbol: "square.stack.3d.up",
                    detail: "Package a reviewed sequence of typed steps so multiple workflows can reuse an exact pinned version."
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func componentGuideCard(title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(KanameColor.accent)
                .frame(width: 24, height: 24)
                .background(KanameColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(KanameColor.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var schedules: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Schedule triggers", systemImage: "calendar.badge.clock").font(.headline)
                    Text("Schedules start workflows or local actions; they never grant effect authority.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(scheduler.ownerState, systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Button("New schedule", systemImage: "plus", action: createSchedule)
                    .buttonStyle(.bordered)
            }
            if model.snapshot.operations.workflows.scheduleBindings.isEmpty && model.snapshot.domains.automations.isEmpty {
                Text("No schedule triggers configured.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.operations.workflows.scheduleBindings) { binding in
                componentRow(
                    title: model.workflowDefinitions.first { $0.id == binding.workflowID }?.name ?? binding.workflowID,
                    detail: "\(binding.spec.frequency.label) \(String(format: "%02d:%02d", binding.spec.hour, binding.spec.minute)) · \(binding.timeZoneIdentifier) · \(binding.missedRunPolicy.label)",
                    version: "Workflow",
                    ready: binding.enabled,
                    status: binding.enabled ? "Enabled" : "Disabled"
                )
            }
            ForEach(model.snapshot.domains.automations) { rule in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "calendar.badge.clock").foregroundStyle(rule.status == .paused ? .secondary : KanameColor.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.name).font(.subheadline.weight(.semibold))
                        Text("\(rule.schedule) · \(rule.timeZoneIdentifier)").font(.caption).foregroundStyle(.secondary)
                        Text(rule.actionSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Edit", systemImage: "slider.horizontal.3") { editSchedule(rule) }.buttonStyle(.bordered)
                    Toggle("Enabled", isOn: Binding(
                        get: { rule.status != .paused },
                        set: { model.setAutomationPaused(id: rule.id, paused: !$0) }
                    ))
                    .labelsHidden()
                }
                .padding(12)
                .background(KanameColor.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func componentSection<Content: View>(
        title: String,
        detail: String,
        symbol: String,
        empty: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityHint(empty)
    }

    private func componentRow(
        title: String,
        detail: String,
        version: String,
        ready: Bool,
        status: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ready ? "checkmark.seal.fill" : "pause.circle")
                .foregroundStyle(ready ? KanameColor.success : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail.isEmpty ? "No additional capabilities declared" : detail)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(version).font(.system(.caption, design: .monospaced))
                Text(status).font(.caption2).foregroundStyle(ready ? KanameColor.success : .secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AutomationReadinessView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @Binding var selectedWorkflowID: String?
    let configureInstallation: (DesktopWorkflowInstallationRecord) -> Void

    private var definition: DesktopWorkflowDefinitionRecord? {
        model.workflowDefinitions.first { $0.id == selectedWorkflowID } ?? model.workflowDefinitions.first
    }

    var body: some View {
        if model.workflowDefinitions.isEmpty {
            EmptyPanel(
                symbol: "checkmark.seal",
                title: "No workflows installed",
                detail: "Install or create a workflow to inspect its readiness."
            )
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            HSplitView {
                workflowList
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 360, maxHeight: .infinity, alignment: .topLeading)
                readinessDetail
                    .frame(minWidth: 650, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var workflowList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Readiness").font(.title3.weight(.bold))
            Text("Bindings, fixtures, permissions, connector health, and promotion gates.")
                .font(.caption).foregroundStyle(.secondary)
            List(model.workflowDefinitions, selection: $selectedWorkflowID) { definition in
                let report = model.workflowMigrationReadiness(workflowID: definition.id)
                HStack {
                    Image(systemName: readinessSymbol(report.isReady ? .ready : .blocked))
                        .foregroundStyle(readinessTint(report.isReady ? .ready : .blocked))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(definition.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(report.isReady ? "Ready to configure" : "\(report.blockedCount) blocked · \(report.attentionCount) attention")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tag(Optional(definition.id))
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var readinessDetail: some View {
        if let definition {
            let report = model.workflowMigrationReadiness(workflowID: definition.id)
            let installations = model.workflowInstallations(workflowID: definition.id)
            let bindings = model.workflowTriggerBindings(workflowID: definition.id)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(definition.name).font(.headline)
                            Text("Published revision, private bindings, and authority remain separate.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label(
                            report.isReady ? "Ready to configure" : "Not ready",
                            systemImage: readinessSymbol(report.isReady ? .ready : .blocked)
                        )
                        .foregroundStyle(readinessTint(report.isReady ? .ready : .blocked))
                    }
                    HStack(spacing: 12) {
                        readinessMetric("Installations", value: installations.count)
                        readinessMetric("Trigger bindings", value: bindings.count)
                        readinessMetric("Google accounts", value: integrations.googleAccounts.count)
                        readinessMetric(
                            "Authority grants",
                            value: model.snapshot.operations.workflows.authorityGrants.filter { $0.workflowID == definition.id }.count
                        )
                    }
                    if installations.isEmpty {
                        BoundaryCallout(
                            title: "No private installation",
                            detail: "Create or import an installation before binding accounts, configuration, retention, or authority. The portable workflow remains unchanged."
                        )
                    } else {
                        ForEach(installations) { installation in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: installation.readinessIssues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(installation.readinessIssues.isEmpty ? KanameColor.success : KanameColor.warning)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(installation.name).font(.subheadline.weight(.semibold))
                                    Text(installation.readinessIssues.isEmpty
                                        ? "Configuration and bindings are ready; authority remains separately gated."
                                        : installation.readinessIssues.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Configure…") { configureInstallation(installation) }.buttonStyle(.bordered)
                            }
                            .padding(12)
                            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Acceptance gates").font(.headline)
                        ForEach(report.checks) { check in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: readinessSymbol(check.state))
                                    .foregroundStyle(readinessTint(check.state)).frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(check.title).font(.subheadline.weight(.semibold))
                                    Text(check.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(check.state.rawValue.capitalized)
                                    .font(.caption2.weight(.bold)).foregroundStyle(readinessTint(check.state))
                            }
                            .padding(10)
                            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(2)
            }
        } else {
            EmptyPanel(symbol: "checkmark.seal", title: "No workflow selected", detail: "Install or create a workflow to inspect readiness.")
        }
    }

    private func readinessMetric(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value, format: .number).font(.title3.weight(.bold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

private func readinessSymbol(_ state: DesktopWorkflowMigrationReadinessState) -> String {
    switch state {
    case .ready: "checkmark.circle.fill"
    case .attention: "exclamationmark.circle.fill"
    case .blocked: "xmark.octagon.fill"
    }
}

private func readinessTint(_ state: DesktopWorkflowMigrationReadinessState) -> Color {
    switch state {
    case .ready: KanameColor.success
    case .attention: KanameColor.warning
    case .blocked: KanameColor.danger
    }
}

struct AutomationWorkflowDesignPreview: View {
    private enum Direction: String, CaseIterable {
        case portfolio = "Workflows"
        case canvas = "Builder"
        case operations = "Run history"
    }

    @State private var direction: Direction
    @State private var selectedWorkflowID = "reply-driven"
    private let showsMatchRoutingDesign: Bool

    init() {
        let arguments = CommandLine.arguments
        showsMatchRoutingDesign = arguments.contains(where: { $0.hasPrefix("--desktop-automation-builder-match") })
        let initial: Direction
        if arguments.contains("--desktop-automation-design-runs") {
            initial = .operations
        } else if arguments.contains(where: { $0.hasPrefix("--desktop-automation-builder") })
                    || arguments.contains("--desktop-automation-canvas-parallel")
                    || arguments.contains("--desktop-automation-canvas-approval")
                    || arguments.contains("--desktop-automation-canvas-feedback")
                    || arguments.contains("--desktop-automation-canvas-recovery")
                    || arguments.contains("--desktop-automation-small-readable")
                    || arguments.contains("--desktop-automation-small-overview")
                    || arguments.contains("--desktop-automation-small-focus")
                    || arguments.contains("--desktop-automation-outline") {
            initial = .canvas
        } else {
            initial = .portfolio
        }
        _direction = State(initialValue: initial)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if proxy.size.width < 950 {
                    compactProductHeader
                } else {
                    SurfaceHeader(
                        title: "Automations",
                        detail: "Design, connect, run, and understand every repeatable workflow",
                        symbol: "point.3.connected.trianglepath.dotted"
                    ) {
                        Label("Design preview", systemImage: "hammer.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KanameColor.warning)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(KanameColor.warning.opacity(0.12), in: Capsule())
                        Button("New workflow", systemImage: "plus") {}
                            .buttonStyle(.borderedProminent)
                            .disabled(true)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 16)
                }

                HStack(spacing: 16) {
                    Picker("Design direction", selection: $direction) {
                        ForEach(Direction.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: proxy.size.width < 950 ? 300 : 390)

                    Spacer()

                    Label(proxy.size.width < 950 ? "Fixture only" : "Fixture data · no live actions", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, proxy.size.width < 950 ? 10 : 16)

                Divider()

                ScrollView {
                    Group {
                        switch direction {
                        case .canvas:
                            if showsMatchRoutingDesign {
                                AutomationMatchRoutingDesignPreview()
                            } else {
                                AutomationCanvasPreview(workflowID: selectedWorkflowID)
                                    .id(selectedWorkflowID)
                            }
                        case .portfolio:
                            AutomationPipelinePreview(
                                workflows: AutomationWorkflowPreview.portfolio,
                                selectedWorkflowID: $selectedWorkflowID,
                                openBuilder: { direction = .canvas },
                                openRunHistory: { direction = .operations },
                                createWorkflow: nil
                            )
                        case .operations:
                            AutomationRunsPreview()
                        }
                    }
                    .padding(proxy.size.width < 950 ? 14 : 20)
                }
            }
            .background(KanameColor.canvas)
        }
    }

    private var compactProductHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(KanameColor.accent)
                .frame(width: 30, height: 30)
                .background(KanameColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Automations").font(.headline.weight(.bold))
                Text("Design, run, and debug repeatable work")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Design preview", systemImage: "hammer.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KanameColor.warning)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(KanameColor.warning.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

private enum AutomationMatchDesignOption: String, CaseIterable, Identifiable {
    case namedPorts = "Named ports"
    case expandedBoard = "Expanded board"
    case objectConditions = "Object rules"
    case errorRecovery = "Error + retry"

    var id: String { rawValue }

    init(arguments: [String]) {
        if arguments.contains("--desktop-automation-builder-match-board") { self = .expandedBoard }
        else if arguments.contains("--desktop-automation-builder-match-object") { self = .objectConditions }
        else if arguments.contains("--desktop-automation-builder-match-error") { self = .errorRecovery }
        else { self = .namedPorts }
    }

    var title: String {
        switch self {
        case .namedPorts: "Option A · Compact Match with named ports"
        case .expandedBoard: "Option B · Expand Match into a switchboard"
        case .objectConditions: "Option C · Match a whole object with compound conditions"
        case .errorRecovery: "Required scenario · Match an error into retry or recovery"
        }
    }

    var summary: String {
        switch self {
        case .namedPorts: "Best for a small, typed set of cases that should remain visible on the canvas"
        case .expandedBoard: "Keeps many cases readable without turning every workflow node into a very tall card"
        case .objectConditions: "Each output arm can combine nested fields with ALL, ANY, and NOT groups"
        case .errorRecovery: "Routes a typed error while keeping retry policy and unknown outcomes explicit"
        }
    }
}

private struct AutomationMatchRoutingDesignPreview: View {
    @State private var option: AutomationMatchDesignOption

    init() {
        _option = State(initialValue: AutomationMatchDesignOption(arguments: CommandLine.arguments))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Match routing").font(.title3.weight(.bold))
                    Text(option.title).font(.caption.weight(.semibold)).foregroundStyle(KanameColor.accent)
                    Text(option.summary).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Match design", selection: $option) {
                    ForEach(AutomationMatchDesignOption.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 480)
                Label("Design only", systemImage: "hammer.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KanameColor.warning)
            }

            HStack(alignment: .top, spacing: 12) {
                AutomationMatchRoutingCanvas(option: option)
                    .frame(maxWidth: .infinity, minHeight: 570)
                AutomationMatchRoutingInspector(option: option)
                    .frame(width: 310)
                    .frame(minHeight: 570)
            }
        }
        .frame(minHeight: 630, alignment: .topLeading)
    }
}

private struct AutomationMatchRoutingCanvas: View {
    let option: AutomationMatchDesignOption

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Label("Canvas", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KanameColor.accent)
                Text("Readable 100%").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Label("One value in", systemImage: "arrow.right")
                Label(option == .errorRecovery ? "One safe route out" : "One matching route out", systemImage: "arrow.triangle.branch")
            }
            .font(.caption2)

            GeometryReader { proxy in
                ZStack {
                    Canvas { context, size in
                        drawRoutes(context: &context, size: size)
                    }
                    .allowsHitTesting(false)

                    switch option {
                    case .namedPorts:
                        namedPortsNodes(size: proxy.size)
                    case .expandedBoard:
                        expandedBoardNodes(size: proxy.size)
                    case .objectConditions:
                        objectConditionNodes(size: proxy.size)
                    case .errorRecovery:
                        errorRecoveryNodes(size: proxy.size)
                    }
                }
            }
            .background {
                Canvas { context, size in
                    var dots = Path()
                    stride(from: CGFloat(14), through: size.width, by: 18).forEach { x in
                        stride(from: CGFloat(14), through: size.height, by: 18).forEach { y in
                            dots.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                        }
                    }
                    context.fill(dots, with: .color(KanameColor.separator.opacity(0.38)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.separator, lineWidth: 1) }

            HStack(spacing: 14) {
                Label("Success", systemImage: "checkmark.circle.fill").foregroundStyle(KanameColor.success)
                Label("Error", systemImage: "xmark.octagon.fill").foregroundStyle(KanameColor.danger)
                Label("Match route", systemImage: "arrow.triangle.branch").foregroundStyle(KanameColor.warning)
                Label("Retry loop", systemImage: "arrow.clockwise").foregroundStyle(KanameColor.external)
                Spacer()
                Text("Case order and fallback are versioned with the workflow")
            }
            .font(.caption2)
        }
        .padding(12)
        .background(KanameColor.surface.opacity(0.46), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func namedPortsNodes(size: CGSize) -> some View {
        outputProducingNode(
            title: "Extract priority",
            subtitle: "Returns Int",
            symbol: "number",
            success: "value",
            error: "error"
        )
        .frame(width: 165)
        .position(x: size.width * 0.13, y: size.height * 0.50)

        compactMatchNode(
            title: "Match priority",
            input: "Success.value · Int",
            cases: [
                ("5", "Urgent path", KanameColor.danger),
                ("8", "Review path", KanameColor.warning),
                ("_", "Otherwise", KanameColor.accent),
            ]
        )
        .frame(width: 230)
        .position(x: size.width * 0.46, y: size.height * 0.50)

        routeDestination("Urgent", detail: "Notify now", symbol: "bell.badge.fill", tint: KanameColor.danger)
            .frame(width: 165)
            .position(x: size.width * 0.82, y: size.height * 0.24)
        routeDestination("Review", detail: "Human decision", symbol: "person.crop.circle.badge.questionmark", tint: KanameColor.warning)
            .frame(width: 165)
            .position(x: size.width * 0.82, y: size.height * 0.50)
        routeDestination("Normal", detail: "Continue", symbol: "arrow.right.circle", tint: KanameColor.accent)
            .frame(width: 165)
            .position(x: size.width * 0.82, y: size.height * 0.76)
    }

    @ViewBuilder
    private func expandedBoardNodes(size: CGSize) -> some View {
        outputProducingNode(
            title: "Classify request",
            subtitle: "Returns String?",
            symbol: "tag",
            success: "code",
            error: "error"
        )
        .frame(width: 165)
        .position(x: size.width * 0.11, y: size.height * 0.50)

        expandedMatchBoard
            .frame(width: 340)
            .position(x: size.width * 0.48, y: size.height * 0.50)

        routeDestination("Fast path", detail: "Codes 5 or 8", symbol: "bolt.fill", tint: KanameColor.success)
            .frame(width: 160)
            .position(x: size.width * 0.84, y: size.height * 0.19)
        routeDestination("Follow-up", detail: "Range 13…19", symbol: "clock.arrow.circlepath", tint: KanameColor.blocked)
            .frame(width: 160)
            .position(x: size.width * 0.84, y: size.height * 0.40)
        routeDestination("Missing value", detail: "Ask for input", symbol: "questionmark.circle", tint: KanameColor.warning)
            .frame(width: 160)
            .position(x: size.width * 0.84, y: size.height * 0.61)
        routeDestination("Default", detail: "Safe fallback", symbol: "arrow.down.right.circle", tint: KanameColor.accent)
            .frame(width: 160)
            .position(x: size.width * 0.84, y: size.height * 0.82)
    }

    @ViewBuilder
    private func objectConditionNodes(size: CGSize) -> some View {
        outputProducingNode(
            title: "Assess request",
            subtitle: "Returns RequestResult",
            symbol: "curlybraces.square",
            success: "result",
            error: "error"
        )
        .frame(width: 175)
        .position(x: size.width * 0.11, y: size.height * 0.50)

        complexObjectMatchBoard
            .frame(width: 380)
            .position(x: size.width * 0.49, y: size.height * 0.50)

        routeDestination("Priority retry", detail: "ALL + nested ANY", symbol: "arrow.clockwise", tint: KanameColor.external)
            .frame(width: 175)
            .position(x: size.width * 0.85, y: size.height * 0.25)
        routeDestination("Manual review", detail: "Risk or missing data", symbol: "person.crop.circle.badge.questionmark", tint: KanameColor.warning)
            .frame(width: 175)
            .position(x: size.width * 0.85, y: size.height * 0.52)
        routeDestination("Standard path", detail: "Otherwise", symbol: "arrow.right.circle", tint: KanameColor.accent)
            .frame(width: 175)
            .position(x: size.width * 0.85, y: size.height * 0.79)
    }

    @ViewBuilder
    private func errorRecoveryNodes(size: CGSize) -> some View {
        outputProducingNode(
            title: "Apply action",
            subtitle: "Idempotent effect",
            symbol: "checkmark.shield",
            success: "receipt",
            error: "Error.kind"
        )
        .frame(width: 175)
        .position(x: size.width * 0.12, y: size.height * 0.42)

        compactMatchNode(
            title: "Match error",
            input: "Error.kind · ErrorKind",
            cases: [
                ("timeout", "Retry", KanameColor.external),
                ("invalid_input", "Review", KanameColor.warning),
                ("unknown", "Reconcile", KanameColor.danger),
                ("_", "Fail safely", KanameColor.accent),
            ]
        )
        .frame(width: 240)
        .position(x: size.width * 0.44, y: size.height * 0.58)

        routeDestination("Receipt", detail: "Success continues", symbol: "doc.text.magnifyingglass", tint: KanameColor.success)
            .frame(width: 165)
            .position(x: size.width * 0.82, y: size.height * 0.15)
        routeDestination("Retry controller", detail: "Max 3 · backoff", symbol: "arrow.clockwise", tint: KanameColor.external)
            .frame(width: 175)
            .position(x: size.width * 0.74, y: size.height * 0.38)
        routeDestination("Human review", detail: "Correct input", symbol: "person.crop.circle.badge.exclamationmark", tint: KanameColor.warning)
            .frame(width: 175)
            .position(x: size.width * 0.80, y: size.height * 0.62)
        routeDestination("Reconcile", detail: "Never auto-retry", symbol: "questionmark.diamond.fill", tint: KanameColor.danger)
            .frame(width: 175)
            .position(x: size.width * 0.80, y: size.height * 0.84)
    }

    private var expandedMatchBoard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(KanameColor.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Match classification.code").font(.caption.weight(.bold))
                    Text("Expanded while selected · String?").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("FIRST MATCH")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(KanameColor.warning)
            }
            .padding(10)
            .background(KanameColor.warning.opacity(0.08))

            expandedBoardRow("01", pattern: "5 | 8", destination: "Fast path", tint: KanameColor.success)
            expandedBoardRow("02", pattern: "13…19", destination: "Follow-up", tint: KanameColor.blocked)
            expandedBoardRow("03", pattern: "null", destination: "Missing value", tint: KanameColor.warning)
            expandedBoardRow("04", pattern: "\"blocked\"", destination: "Human review", tint: KanameColor.danger)
            expandedBoardRow("05", pattern: "_ otherwise", destination: "Default", tint: KanameColor.accent)
            Button("Add case", systemImage: "plus") {}
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(KanameColor.accent)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.warning.opacity(0.52), lineWidth: 1.4) }
    }

    private var complexObjectMatchBoard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(KanameColor.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Match success.result").font(.caption.weight(.bold))
                    Text("RequestResult object · first match").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("COMPOUND")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(KanameColor.warning)
            }
            .padding(10)
            .background(KanameColor.warning.opacity(0.08))

            compoundCaseRow(
                "01",
                title: "Priority retry",
                summary: "ALL 2 · nested ANY 1 of 2",
                tint: KanameColor.external
            )
            compoundCaseRow(
                "02",
                title: "Manual review",
                summary: "ANY 2 conditions",
                tint: KanameColor.warning
            )
            compoundCaseRow(
                "03",
                title: "Otherwise",
                summary: "Every valid unmatched value",
                tint: KanameColor.accent
            )

            HStack(spacing: 10) {
                Label("String", systemImage: "textformat")
                Label("Number", systemImage: "number")
                Label("Object", systemImage: "curlybraces")
                Label("Array", systemImage: "square.stack.3d.up")
            }
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(9)
        }
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.warning.opacity(0.52), lineWidth: 1.4) }
    }

    private func compoundCaseRow(_ index: String, title: String, summary: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(index).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            Image(systemName: title == "Otherwise" ? "arrow.down.right" : "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 9))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2.weight(.bold))
                Text(summary).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(tint).frame(width: 8, height: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(KanameColor.canvas.opacity(0.55))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func expandedBoardRow(_ index: String, pattern: String, destination: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(index).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            Text(pattern).font(.system(.caption2, design: .monospaced).weight(.semibold)).frame(width: 80, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(tint)
            Text(destination).font(.caption2).lineLimit(1)
            Spacer()
            Circle().fill(tint).frame(width: 8, height: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(KanameColor.canvas.opacity(0.55))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func outputProducingNode(
        title: String,
        subtitle: String,
        symbol: String,
        success: String,
        error: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption.weight(.bold))
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            Divider()
            outputPort("Success · \(success)", tint: KanameColor.success)
            outputPort("Error · \(error)", tint: KanameColor.danger)
        }
        .padding(10)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(KanameColor.accent.opacity(0.45), lineWidth: 1) }
    }

    private func outputPort(_ label: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
            Spacer()
            Circle().fill(tint).frame(width: 8, height: 8)
        }
    }

    private func compactMatchNode(
        title: String,
        input: String,
        cases: [(String, String, Color)]
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(KanameColor.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.bold))
                    Text("Typed · first match").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(KanameColor.warning.opacity(0.08))

            HStack(spacing: 6) {
                Circle().fill(KanameColor.accent).frame(width: 7, height: 7)
                Text(input).font(.system(size: 9, weight: .semibold, design: .monospaced)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(KanameColor.canvas.opacity(0.65))

            ForEach(Array(cases.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 7) {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(item.0)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .frame(width: 68, alignment: .leading)
                    Text(item.1).font(.caption2).lineLimit(1)
                    Spacer(minLength: 0)
                    Circle().fill(item.2).frame(width: 8, height: 8)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    if index < cases.count - 1 { Divider() }
                }
            }
        }
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.warning.opacity(0.58), lineWidth: 1.5) }
    }

    private func routeDestination(_ title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.bold)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.46), lineWidth: 1) }
    }

    private func drawRoutes(context: inout GraphicsContext, size: CGSize) {
        switch option {
        case .namedPorts:
            drawRoute(&context, from: CGPoint(x: size.width * 0.13 + 82, y: size.height * 0.50 + 13), to: CGPoint(x: size.width * 0.46 - 115, y: size.height * 0.50 - 40), tint: KanameColor.success)
            drawRoute(&context, from: CGPoint(x: size.width * 0.46 + 115, y: size.height * 0.50 - 10), to: CGPoint(x: size.width * 0.82 - 82, y: size.height * 0.24), tint: KanameColor.danger)
            drawRoute(&context, from: CGPoint(x: size.width * 0.46 + 115, y: size.height * 0.50 + 25), to: CGPoint(x: size.width * 0.82 - 82, y: size.height * 0.50), tint: KanameColor.warning)
            drawRoute(&context, from: CGPoint(x: size.width * 0.46 + 115, y: size.height * 0.50 + 60), to: CGPoint(x: size.width * 0.82 - 82, y: size.height * 0.76), tint: KanameColor.accent)
        case .expandedBoard:
            drawRoute(&context, from: CGPoint(x: size.width * 0.11 + 82, y: size.height * 0.50 + 13), to: CGPoint(x: size.width * 0.48 - 170, y: size.height * 0.50 - 125), tint: KanameColor.success)
            let boardX = size.width * 0.48 + 170
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 - 78), to: CGPoint(x: size.width * 0.84 - 80, y: size.height * 0.19), tint: KanameColor.success)
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 - 38), to: CGPoint(x: size.width * 0.84 - 80, y: size.height * 0.40), tint: KanameColor.blocked)
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 + 2), to: CGPoint(x: size.width * 0.84 - 80, y: size.height * 0.61), tint: KanameColor.warning)
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 + 82), to: CGPoint(x: size.width * 0.84 - 80, y: size.height * 0.82), tint: KanameColor.accent)
        case .objectConditions:
            drawRoute(&context, from: CGPoint(x: size.width * 0.11 + 87, y: size.height * 0.50 + 13), to: CGPoint(x: size.width * 0.49 - 190, y: size.height * 0.50 - 70), tint: KanameColor.success)
            let boardX = size.width * 0.49 + 190
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 - 42), to: CGPoint(x: size.width * 0.85 - 87, y: size.height * 0.25), tint: KanameColor.external)
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 + 10), to: CGPoint(x: size.width * 0.85 - 87, y: size.height * 0.52), tint: KanameColor.warning)
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 + 64), to: CGPoint(x: size.width * 0.85 - 87, y: size.height * 0.79), tint: KanameColor.accent)
        case .errorRecovery:
            drawRoute(&context, from: CGPoint(x: size.width * 0.12 + 87, y: size.height * 0.42 - 7), to: CGPoint(x: size.width * 0.82 - 82, y: size.height * 0.15), tint: KanameColor.success)
            drawRoute(&context, from: CGPoint(x: size.width * 0.12 + 87, y: size.height * 0.42 + 25), to: CGPoint(x: size.width * 0.44 - 120, y: size.height * 0.58 - 54), tint: KanameColor.danger)
            drawRoute(&context, from: CGPoint(x: size.width * 0.44 + 120, y: size.height * 0.58 - 18), to: CGPoint(x: size.width * 0.74 - 87, y: size.height * 0.38), tint: KanameColor.external)
            drawRoute(&context, from: CGPoint(x: size.width * 0.44 + 120, y: size.height * 0.58 + 18), to: CGPoint(x: size.width * 0.80 - 87, y: size.height * 0.62), tint: KanameColor.warning)
            drawRoute(&context, from: CGPoint(x: size.width * 0.44 + 120, y: size.height * 0.58 + 54), to: CGPoint(x: size.width * 0.80 - 87, y: size.height * 0.84), tint: KanameColor.danger)
            drawRetryLoop(&context, size: size)
        }
    }

    private func drawRoute(
        _ context: inout GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        tint: Color
    ) {
        var path = Path()
        path.move(to: start)
        let distance = max(44, abs(end.x - start.x) * 0.44)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + distance, y: start.y),
            control2: CGPoint(x: end.x - distance, y: end.y)
        )
        context.stroke(path, with: .color(tint.opacity(0.78)), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))

        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: end.x - 8, y: end.y - 5))
        arrow.addLine(to: CGPoint(x: end.x - 8, y: end.y + 5))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(tint))
    }

    private func drawRetryLoop(_ context: inout GraphicsContext, size: CGSize) {
        let start = CGPoint(x: size.width * 0.74, y: size.height * 0.38 - 38)
        let end = CGPoint(x: size.width * 0.12, y: size.height * 0.42 - 68)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x, y: size.height * 0.05),
            control2: CGPoint(x: end.x, y: size.height * 0.05)
        )
        context.stroke(path, with: .color(KanameColor.external.opacity(0.9)), style: StrokeStyle(lineWidth: 2.4, dash: [8, 5]))

        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: end.x + 8, y: end.y - 5))
        arrow.addLine(to: CGPoint(x: end.x + 8, y: end.y + 5))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(KanameColor.external))
    }
}

private struct AutomationMatchRoutingInspector: View {
    let option: AutomationMatchDesignOption

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(KanameColor.warning)
                    .frame(width: 30, height: 30)
                    .background(KanameColor.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(inspectorTitle).font(.headline)
                    Text("Deterministic routing · no side effects").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider()
            inspectorField("Input value", value: inputValue, symbol: option == .errorRecovery ? "xmark.octagon" : "arrow.down.doc")
            inspectorField("Input type", value: inputType, symbol: "curlybraces")
            inspectorField("Selection", value: "First matching case", symbol: "list.number")

            HStack(spacing: 7) {
                Label("Typed", systemImage: "checkmark.seal.fill")
                Label("Ordered", systemImage: "arrow.down")
                Label("Exhaustive", systemImage: "checkmark.circle.fill")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(KanameColor.success)

            Divider()
            HStack {
                Text("Cases").font(.caption.weight(.bold))
                Spacer()
                Text(caseCount).font(.caption2).foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(cases.enumerated()), id: \.offset) { index, item in
                    inspectorCase(index + 1, pattern: item.0, destination: item.1, tint: item.2)
                    if index < cases.count - 1 { Divider() }
                }
            }
            .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 9))

            Button("Add case", systemImage: "plus") {}
                .buttonStyle(.bordered)

            if option == .objectConditions {
                complexConditionPanel
            } else if option == .errorRecovery {
                errorSafetyPanel
            } else {
                Label("A value that matches no explicit case must use Otherwise; silent dropping is not allowed.", systemImage: "shield.fill")
                    .font(.caption2)
                    .foregroundStyle(KanameColor.warning)
                    .padding(9)
                    .background(KanameColor.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)
            Divider()
            Label("Run history records the input value, selected case, and route edge.", systemImage: "clock.arrow.circlepath")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var inspectorTitle: String {
        switch option {
        case .objectConditions: "Match object"
        case .errorRecovery: "Match error"
        default: "Match value"
        }
    }

    private var inputValue: String {
        switch option {
        case .namedPorts: "Extract priority → Success.value"
        case .expandedBoard: "Classify request → Success.code"
        case .objectConditions: "Assess request → Success.result"
        case .errorRecovery: "Apply action → Error.kind"
        }
    }

    private var inputType: String {
        switch option {
        case .namedPorts: "Int"
        case .expandedBoard: "String?"
        case .objectConditions: "RequestResult object"
        case .errorRecovery: "ErrorKind"
        }
    }

    private var caseCount: String {
        "\(cases.count) outputs"
    }

    private var cases: [(String, String, Color)] {
        switch option {
        case .namedPorts:
            [("5", "Urgent", KanameColor.danger), ("8", "Review", KanameColor.warning), ("_", "Normal", KanameColor.accent)]
        case .expandedBoard:
            [("5 | 8", "Fast path", KanameColor.success), ("13…19", "Follow-up", KanameColor.blocked), ("null", "Missing value", KanameColor.warning), ("\"blocked\"", "Human review", KanameColor.danger), ("_", "Default", KanameColor.accent)]
        case .objectConditions:
            [("ALL + ANY", "Priority retry", KanameColor.external), ("ANY", "Manual review", KanameColor.warning), ("_", "Standard path", KanameColor.accent)]
        case .errorRecovery:
            [(".timeout", "Retry controller", KanameColor.external), (".invalidInput", "Human review", KanameColor.warning), (".unknownOutcome", "Reconcile", KanameColor.danger), ("_", "Fail safely", KanameColor.accent)]
        }
    }

    private func inspectorField(_ label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func inspectorCase(_ index: Int, pattern: String, destination: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Text(String(format: "%02d", index))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Circle().fill(tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(pattern).font(.system(.caption2, design: .monospaced).weight(.bold))
                Text(destination).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "line.diagonal.arrow").font(.caption2).foregroundStyle(tint)
        }
        .padding(8)
    }

    private var errorSafetyPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Retry remains a control node", systemImage: "arrow.clockwise.circle.fill")
                .font(.caption.weight(.bold)).foregroundStyle(KanameColor.external)
            safetyRow("Maximum attempts", value: "3")
            safetyRow("Backoff", value: "2 s · ×2 · jitter")
            safetyRow("Idempotency", value: "Required")
            safetyRow("Unknown outcome", value: "Never auto-retry")
        }
        .padding(9)
        .background(KanameColor.external.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(KanameColor.external.opacity(0.28), lineWidth: 1) }
    }

    private var complexConditionPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Priority retry", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(KanameColor.external)
                Spacer()
                Text("ALL").font(.system(size: 9, weight: .bold, design: .monospaced))
            }

            conditionRow("status", relation: "equals", value: "failed", tint: KanameColor.success)
            conditionRow("error.retryable", relation: "is", value: "true", tint: KanameColor.success)

            HStack {
                Text("AND").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                Divider()
                Text("ANY · 1 of 2").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(KanameColor.accent)
                Spacer()
                Button("+ condition") {}.buttonStyle(.plain).font(.system(size: 9))
            }
            .frame(height: 18)

            conditionRow("customer.tier", relation: "equals", value: "priority", tint: KanameColor.accent)
            conditionRow("value", relation: "≥", value: "10,000", tint: KanameColor.accent)

            HStack(spacing: 7) {
                Button("+ AND") {}.buttonStyle(.bordered).controlSize(.mini)
                Button("+ ANY") {}.buttonStyle(.bordered).controlSize(.mini)
                Button("+ NOT") {}.buttonStyle(.bordered).controlSize(.mini)
                Spacer()
                Label("Fixture matched", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(KanameColor.success)
            }
        }
        .padding(9)
        .background(KanameColor.external.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(KanameColor.external.opacity(0.26), lineWidth: 1) }
    }

    private func conditionRow(_ field: String, relation: String, value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(field).font(.system(size: 9, weight: .semibold, design: .monospaced)).lineLimit(1)
            Text(relation).font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(tint).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 6))
    }

    private func safetyRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.caption2)
    }
}

private enum AutomationPreviewState {
    case complete
    case running
    case waiting
    case blocked
    case planned
    /// The compiler would execute this node as configured.
    case executable
    /// The compiler keeps this node schema-only; see the node's reason.
    case schemaOnly

    var label: String {
        switch self {
        case .complete: "Complete"
        case .running: "Running"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .planned: "Planned"
        case .executable: "Executable"
        case .schemaOnly: "Not executable"
        }
    }

    var symbol: String {
        switch self {
        case .complete: "checkmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath.circle.fill"
        case .waiting: "pause.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .planned: "circle.dashed"
        case .executable: "bolt.circle.fill"
        case .schemaOnly: "bolt.slash.circle"
        }
    }

    var tint: Color {
        switch self {
        case .complete: KanameColor.success
        case .running: KanameColor.accent
        case .waiting: KanameColor.warning
        case .blocked: KanameColor.danger
        case .planned: Color.secondary
        case .executable: KanameColor.success
        case .schemaOnly: KanameColor.warning
        }
    }
}

private struct AutomationWorkflowPreview: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let progress: Int
    let state: AutomationPreviewState
    let version: String
    let trigger: String
    let lastRun: String
    let retention: String

    static let portfolio: [Self] = [
        .init(id: "reply-driven", name: "Reply-driven reporting", summary: "Synthetic fixture · not operational · Produce, deliver, and revise artifacts through email", symbol: "arrow.trianglehead.2.clockwise.rotate.90", progress: 3, state: .waiting, version: "6", trigger: "Email reply", lastRun: "Waiting · 12 min", retention: "30 days"),
        .init(id: "mailbox-review", name: "Mailbox review", summary: "Synthetic fixture · not operational · Review and classify incoming mail", symbol: "tray.full", progress: 3, state: .running, version: "4", trigger: "Every hour", lastRun: "Running · now", retention: "30 days"),
        .init(id: "approved-cleanup", name: "Approved cleanup", summary: "Synthetic fixture · not operational · Apply reviewed labels and archive", symbol: "archivebox", progress: 2, state: .waiting, version: "3", trigger: "Manual", lastRun: "Waiting · 2 h", retention: "30 days"),
        .init(id: "sender-cleanup", name: "Sender cleanup", summary: "Synthetic fixture · not operational · Exact-scope recurring cleanup", symbol: "scope", progress: 1, state: .planned, version: "1", trigger: "Daily 09:00", lastRun: "Never", retention: "After success"),
        .init(id: "financial-filing", name: "Financial filing", summary: "Synthetic fixture · not operational · Preserve and file financial mail", symbol: "doc.text", progress: 2, state: .waiting, version: "5", trigger: "New mail", lastRun: "Passed · yesterday", retention: "Forever"),
        .init(id: "structured-ingestion", name: "Structured ingestion", summary: "Synthetic fixture · not operational · Parse messages into a dataset", symbol: "tablecells", progress: 2, state: .blocked, version: "2", trigger: "New mail", lastRun: "Blocked · 3 d", retention: "30 days"),
        .init(id: "newsletter", name: "Newsletter management", summary: "Synthetic fixture · not operational · Review subscriptions and cleanup", symbol: "newspaper", progress: 1, state: .planned, version: "1", trigger: "Weekly", lastRun: "Never", retention: "30 days"),
        .init(id: "correspondence", name: "Correspondence", summary: "Synthetic fixture · not operational · Draft, review, reply, and forward", symbol: "arrowshape.turn.up.left", progress: 1, state: .planned, version: "2", trigger: "Manual", lastRun: "Passed · 8 d", retention: "30 days"),
        .init(id: "filter-management", name: "Filter management", summary: "Synthetic fixture · not operational · Preview and reconcile provider rules", symbol: "line.3.horizontal.decrease.circle", progress: 1, state: .planned, version: "1", trigger: "Manual", lastRun: "Never", retention: "After success"),
    ]
}

private struct AutomationMigrationProgress: View {
    let completed: Int
    private let labels = ["Designed", "Tested", "Shadowed", "Live"]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                Circle()
                    .fill(index < completed ? KanameColor.success : KanameColor.separator)
                    .frame(width: 7, height: 7)
                    .help(label)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Migration: \(completed) of \(labels.count) stages complete")
    }
}

private struct AutomationPipelinePreview: View {
    let workflows: [AutomationWorkflowPreview]
    @Binding var selectedWorkflowID: String
    let openBuilder: () -> Void
    let openRunHistory: () -> Void
    let createWorkflow: (() -> Void)?
    @State private var search = ""
    @State private var filter = WorkflowLibraryFilter.all

    private enum WorkflowLibraryFilter: String, CaseIterable {
        case all = "All"
        case active = "Active"
        case drafts = "Drafts"
        case attention = "Attention"
    }

    private var selectedWorkflow: AutomationWorkflowPreview {
        workflows.first(where: { $0.id == selectedWorkflowID })
            ?? workflows.first
            ?? AutomationWorkflowPreview.portfolio[0]
    }

    private var visibleWorkflows: [AutomationWorkflowPreview] {
        workflows.filter { workflow in
            let searchMatches = search.isEmpty
                || workflow.name.localizedCaseInsensitiveContains(search)
                || workflow.summary.localizedCaseInsensitiveContains(search)
            let filterMatches: Bool
            switch filter {
            case .all: filterMatches = true
            case .active: filterMatches = [.running, .waiting, .complete].contains(workflow.state)
            case .drafts: filterMatches = workflow.state == .planned
            case .attention: filterMatches = workflow.state == .blocked
            }
            return searchMatches && filterMatches
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 1_050
            VStack(alignment: .leading, spacing: 14) {
                if isCompact {
                    libraryTitle
                    libraryControls
                } else {
                    HStack(spacing: 12) {
                        libraryTitle
                        Spacer()
                        libraryControls
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    workflowTable(isCompact: isCompact)
                        .frame(maxWidth: .infinity)
                    workflowSummary
                        .frame(width: 270)
                }
            }
        }
        .frame(minHeight: 570)
    }

    private var libraryTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Workflow library").font(.title3.weight(.bold))
            Text("Every workflow, trigger, published version, last run, and retention policy")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var libraryControls: some View {
        HStack(spacing: 12) {
            TextField("Search workflows", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 230)
            Picker("Filter", selection: $filter) {
                ForEach(WorkflowLibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            Button("New workflow", systemImage: "plus") { createWorkflow?() }
                .buttonStyle(.borderedProminent)
                .disabled(createWorkflow == nil)
        }
    }

    private func workflowTable(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Workflow").frame(maxWidth: .infinity, alignment: .leading)
                Text("State").frame(width: 95, alignment: .leading)
                if !isCompact {
                    Text("Trigger").frame(width: 100, alignment: .leading)
                }
                Text("Version").frame(width: 60, alignment: .leading)
                if !isCompact {
                    Text("Last run").frame(width: 105, alignment: .leading)
                }
                Text("Retention").frame(width: 92, alignment: .leading)
                Color.clear.frame(width: 8, height: 1)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            ForEach(visibleWorkflows) { workflow in
                Button {
                    selectedWorkflowID = workflow.id
                    openBuilder()
                } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: 9) {
                            Image(systemName: workflow.symbol)
                                .frame(width: 22)
                                .foregroundStyle(workflow.state.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workflow.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(workflow.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Label(workflow.state.label, systemImage: workflow.state.symbol)
                            .foregroundStyle(workflow.state.tint)
                            .frame(width: 95, alignment: .leading)
                        if !isCompact {
                            Text(workflow.trigger).frame(width: 100, alignment: .leading)
                        }
                        Text("v\(workflow.version)").font(.system(.caption, design: .monospaced)).frame(width: 60, alignment: .leading)
                        if !isCompact {
                            Text(workflow.lastRun).frame(width: 105, alignment: .leading)
                        }
                        Text(workflow.retention).frame(width: 92, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        selectedWorkflowID == workflow.id ? KanameColor.accent.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var workflowSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: selectedWorkflow.symbol)
                    .foregroundStyle(selectedWorkflow.state.tint)
                    .frame(width: 34, height: 34)
                    .background(selectedWorkflow.state.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedWorkflow.name).font(.headline)
                    Text("Published v\(selectedWorkflow.version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(selectedWorkflow.summary).font(.caption).foregroundStyle(.secondary)
            Divider()
            libraryFact("State", value: selectedWorkflow.state.label)
            libraryFact("Trigger", value: selectedWorkflow.trigger)
            libraryFact("Last run", value: selectedWorkflow.lastRun)
            libraryFact("History", value: selectedWorkflow.retention)
            Divider()
            Text("Migration").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            AutomationMigrationProgress(completed: selectedWorkflow.progress)
            Text("Designed · Tested · Shadowed · Live")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Open in Builder", systemImage: "point.3.connected.trianglepath.dotted") {
                openBuilder()
            }
                .buttonStyle(.borderedProminent)
            Button("View run history", systemImage: "clock.arrow.circlepath") {
                openRunHistory()
            }
                .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(minHeight: 520, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func libraryFact(_ label: String, value: String) -> some View {
        LabeledContent(label) { Text(value).foregroundStyle(.secondary) }
            .font(.caption)
    }
}

private struct AutomationPipelineStrip: View {
    let stages: [(String, String, AutomationPreviewState)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    VStack(spacing: 7) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(KanameColor.raised)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(stage.2.tint.opacity(stage.2 == .running ? 0.95 : 0.35), lineWidth: stage.2 == .running ? 2 : 1)
                                }
                            Image(systemName: stage.1)
                                .foregroundStyle(stage.2.tint)
                                .scaleEffect(stage.2 == .running && !reduceMotion ? 1 + sin(phase * 4) * 0.08 : 1)
                        }
                        .frame(height: 54)
                        Text(stage.0).font(.caption2.weight(.semibold)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)

                    if index < stages.count - 1 {
                        Rectangle()
                            .fill(index < 3 ? KanameColor.success.opacity(0.8) : KanameColor.separator)
                            .frame(width: 12, height: 2)
                            .overlay(alignment: .trailing) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(index < 3 ? KanameColor.success : .secondary)
                            }
                            .padding(.bottom, 23)
                    }
                }
            }
        }
        .padding(14)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

private enum AutomationCanvasPattern: String, CaseIterable, Identifiable {
    case decision = "Decision"
    case parallel = "Parallel"
    case approval = "Approval"
    case feedback = "Feedback"
    case recovery = "Recovery"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .decision: "Route one input by a deterministic outcome"
        case .parallel: "Fan out independent work and join its results"
        case .approval: "Pause, revise, wait, and resume durably"
        case .feedback: "Keep one case alive across replies, revisions, and attachments"
        case .recovery: "Separate retryable failures from unknown outcomes"
        }
    }

    var title: String {
        switch self {
        case .decision: "Mailbox review / Decision"
        case .parallel: "Mailbox review / Parallel work"
        case .approval: "Correspondence / Approval"
        case .feedback: "Reply-driven case / Episode 3"
        case .recovery: "Approved effect / Recovery"
        }
    }

    var graph: AutomationCanvasGraph {
        switch self {
        case .decision:
            AutomationCanvasGraph(
                defaultSelectedID: "classify",
                groups: [
                    .init(id: "read", title: "READ-ONLY", x: 0.02, y: 0.08, width: 0.67, height: 0.84, tint: KanameColor.accent),
                    .init(id: "routes", title: "ROUTED OUTPUTS", x: 0.71, y: 0.08, width: 0.27, height: 0.84, tint: KanameColor.warning),
                ],
                steps: [
                    .init(id: "trigger", title: "New mail", subtitle: "Account-scoped trigger", symbol: "envelope.badge", kind: .trigger, x: 0.10, y: 0.50, state: .complete, input: "Mail event", output: "Message reference", authority: "Observe only"),
                    .init(id: "freeze", title: "Freeze result", subtitle: "Complete pagination", symbol: "snowflake", kind: .data, x: 0.32, y: 0.50, state: .complete, input: "Search query", output: "Frozen batch", authority: "Read mail"),
                    .init(id: "classify", title: "Classify", subtitle: "Deterministic policy", symbol: "arrow.triangle.branch", kind: .decision, x: 0.57, y: 0.50, state: .running, input: "Frozen batch", output: "Three typed routes", authority: "No effect authority"),
                    .init(id: "protected", title: "Protected", subtitle: "Record exclusion", symbol: "shield.fill", kind: .policy, x: 0.84, y: 0.20, state: .complete, input: "Protected items", output: "Exclusion receipt", authority: "No effect"),
                    .init(id: "eligible", title: "Eligible", subtitle: "Continue subflow", symbol: "square.stack.3d.up", kind: .subflow, x: 0.84, y: 0.50, state: .waiting, input: "Eligible items", output: "Reviewed proposal", authority: "Inherited: none"),
                    .init(id: "uncertain", title: "Needs review", subtitle: "Human decision", symbol: "person.crop.circle.badge.questionmark", kind: .human, x: 0.84, y: 0.80, state: .waiting, input: "Uncertain items", output: "Reviewed route", authority: "Decision only"),
                ],
                edges: [
                    .init("trigger", "freeze", label: "message", kind: .data, active: true),
                    .init("freeze", "classify", label: "184 items", kind: .data, active: true),
                    .init("classify", "protected", label: "protected", kind: .conditional, active: false),
                    .init("classify", "eligible", label: "eligible", kind: .success, active: false),
                    .init("classify", "uncertain", label: "uncertain", kind: .conditional, active: true),
                ]
            )
        case .parallel:
            AutomationCanvasGraph(
                defaultSelectedID: "fanout",
                groups: [
                    .init(id: "parallel", title: "PARALLEL LANES", x: 0.34, y: 0.07, width: 0.42, height: 0.86, tint: KanameColor.blocked),
                ],
                steps: [
                    .init(id: "batch", title: "Frozen batch", subtitle: "184 messages", symbol: "shippingbox", kind: .data, x: 0.10, y: 0.50, state: .complete, input: "Query result", output: "Mail batch", authority: "Read only"),
                    .init(id: "fanout", title: "Fan out", subtitle: "Start 3 lanes", symbol: "arrow.triangle.branch", kind: .parallel, x: 0.30, y: 0.50, state: .running, input: "Mail batch", output: "Three streams", authority: "No effect"),
                    .init(id: "label", title: "Plan labels", subtitle: "Deterministic", symbol: "tag", kind: .data, x: 0.54, y: 0.20, state: .running, input: "Mail stream", output: "Label plan", authority: "Proposal only"),
                    .init(id: "extract", title: "Extract fields", subtitle: "Private capability", symbol: "tablecells", kind: .subflow, x: 0.54, y: 0.50, state: .running, input: "Mail stream", output: "Dataset rows", authority: "Private dataset"),
                    .init(id: "summarize", title: "Summarize", subtitle: "Minimum projection", symbol: "sparkles", kind: .ai, x: 0.54, y: 0.80, state: .running, input: "Allowed fields", output: "Short summary", authority: "Declared egress"),
                    .init(id: "join", title: "Join", subtitle: "Wait for all lanes", symbol: "arrow.triangle.merge", kind: .join, x: 0.74, y: 0.50, state: .waiting, input: "3 typed results", output: "Combined result", authority: "No effect"),
                    .init(id: "receipt", title: "Receipt", subtitle: "One evidence set", symbol: "doc.text.magnifyingglass", kind: .receipt, x: 0.91, y: 0.50, state: .planned, input: "Combined result", output: "Run evidence", authority: "Local write"),
                ],
                edges: [
                    .init("batch", "fanout", label: "batch", kind: .data, active: true),
                    .init("fanout", "label", label: "lane 1", kind: .parallel, active: true),
                    .init("fanout", "extract", label: "lane 2", kind: .parallel, active: true),
                    .init("fanout", "summarize", label: "lane 3", kind: .parallel, active: true),
                    .init("label", "join", label: "plan", kind: .parallel, active: true),
                    .init("extract", "join", label: "rows", kind: .parallel, active: true),
                    .init("summarize", "join", label: "summary", kind: .parallel, active: true),
                    .init("join", "receipt", label: "all complete", kind: .success, active: false),
                ]
            )
        case .approval:
            AutomationCanvasGraph(
                defaultSelectedID: "approval",
                groups: [
                    .init(id: "human", title: "HUMAN BOUNDARY", x: 0.25, y: 0.08, width: 0.34, height: 0.84, tint: KanameColor.warning),
                    .init(id: "effect", title: "APPROVED EFFECT", x: 0.61, y: 0.08, width: 0.37, height: 0.84, tint: KanameColor.danger),
                ],
                steps: [
                    .init(id: "draft", title: "Prepare draft", subtitle: "No send", symbol: "square.and.pencil", kind: .data, x: 0.10, y: 0.50, state: .complete, input: "Full thread", output: "Draft proposal", authority: "Draft only"),
                    .init(id: "approval", title: "Review", subtitle: "Recipients + content", symbol: "person.crop.circle.badge.checkmark", kind: .human, x: 0.40, y: 0.50, state: .waiting, input: "Draft proposal", output: "Approve or revise", authority: "Human decision"),
                    .init(id: "send", title: "Send", subtitle: "Idempotent effect", symbol: "paperplane.fill", kind: .effect, x: 0.69, y: 0.27, state: .planned, input: "Approved envelope", output: "Provider receipt", authority: "Exact send approval"),
                    .init(id: "revise", title: "Revise", subtitle: "Return to review", symbol: "arrow.uturn.backward", kind: .loop, x: 0.69, y: 0.73, state: .planned, input: "Review notes", output: "New draft revision", authority: "No send"),
                    .init(id: "wait", title: "Wait for reply", subtitle: "Durable resume", symbol: "clock.badge", kind: .wait, x: 0.89, y: 0.27, state: .planned, input: "Sent thread", output: "Reply event", authority: "Observe only"),
                ],
                edges: [
                    .init("draft", "approval", label: "proposal", kind: .data, active: true),
                    .init("approval", "send", label: "approve", kind: .success, active: false),
                    .init("approval", "revise", label: "changes", kind: .conditional, active: true),
                    .init("revise", "approval", label: "revision 2", kind: .loop, active: true),
                    .init("send", "wait", label: "reconciled", kind: .success, active: false),
                ]
            )
        case .feedback:
            AutomationCanvasGraph(
                defaultSelectedID: "context",
                groups: [
                    .init(id: "case", title: "CASE-184 · ONE DURABLE CONVERSATION", x: 0.02, y: 0.05, width: 0.96, height: 0.90, tint: KanameColor.accent),
                    .init(id: "effect-wait", title: "EFFECT + DURABLE WAIT", x: 0.80, y: 0.08, width: 0.18, height: 0.70, tint: KanameColor.danger),
                    .init(id: "episodes", title: "FEEDBACK EPISODES · ARTIFACT LINEAGE", x: 0.36, y: 0.68, width: 0.62, height: 0.27, tint: KanameColor.blocked),
                ],
                steps: [
                    .init(id: "inbound", title: "Inbound email", subtitle: "New message or reply", symbol: "envelope.badge", kind: .trigger, x: 0.09, y: 0.28, state: .complete, input: "Scoped mail event", output: "Thread + message refs", authority: "Observe only"),
                    .init(id: "correlate", title: "Correlate case", subtitle: "Thread + durable case ID", symbol: "link", kind: .decision, x: 0.27, y: 0.28, state: .complete, input: "Thread reference", output: "Existing or new case", authority: "No effect"),
                    .init(id: "context", title: "Compile context", subtitle: "Episodes + current facts", symbol: "text.append", kind: .context, x: 0.46, y: 0.28, state: .running, input: "Case history + artifacts", output: "Bounded context pack", authority: "Private case data"),
                    .init(id: "execute", title: "Run work type", subtitle: "Pinned private subflow", symbol: "square.stack.3d.up", kind: .subflow, x: 0.65, y: 0.28, state: .planned, input: "Context + current inputs", output: "Artifact revision", authority: "Subflow contract"),
                    .init(id: "verify", title: "Verify all", subtitle: "Whole-request checks", symbol: "checkmark.seal", kind: .policy, x: 0.83, y: 0.28, state: .planned, input: "Artifact + acceptance rules", output: "Verified revision", authority: "No send"),
                    .init(id: "reply", title: "Reply + attach", subtitle: "Same email thread", symbol: "paperplane.fill", kind: .effect, x: 0.90, y: 0.50, state: .planned, input: "Verified artifact v3", output: "Provider receipt", authority: "Exact send approval"),
                    .init(id: "wait", title: "Wait for reply", subtitle: "Sending is not completion", symbol: "clock.badge", kind: .wait, x: 0.90, y: 0.72, state: .waiting, input: "Thread checkpoint", output: "Reply event", authority: "Observe only"),
                    .init(id: "interpret", title: "Interpret reply", subtitle: "Accept, correct, clarify", symbol: "arrow.triangle.branch", kind: .decision, x: 0.70, y: 0.80, state: .running, input: "Reply + case context", output: "Typed response route", authority: "No effect"),
                    .init(id: "append", title: "Append episode", subtitle: "Supersede, never erase", symbol: "text.badge.plus", kind: .context, x: 0.46, y: 0.80, state: .planned, input: "Correction or new file", output: "Episode 4 + artifact refs", authority: "Private case write"),
                    .init(id: "close", title: "Close case", subtitle: "Accepted or manually closed", symbol: "checkmark.circle.fill", kind: .receipt, x: 0.90, y: 0.92, state: .planned, input: "Accepted outcome", output: "Case receipt", authority: "Local state only"),
                ],
                edges: [
                    .init("inbound", "correlate", label: "mail event", kind: .data, active: true),
                    .init("correlate", "context", label: "same case", kind: .success, active: true),
                    .init("context", "execute", label: "episode 3", kind: .data, active: true),
                    .init("execute", "verify", label: "artifact v3", kind: .data, active: false),
                    .init("verify", "reply", label: "all checks pass", kind: .success, active: false),
                    .init("reply", "wait", label: "sent + reconciled", kind: .success, active: false),
                    .init("wait", "interpret", label: "reply received", kind: .data, active: true),
                    .init("interpret", "close", label: "accepted", kind: .success, active: false),
                    .init("interpret", "append", label: "change / clarify / file", kind: .conditional, active: true),
                    .init("append", "context", label: "episode 4 · same case", kind: .loop, active: true),
                ]
            )
        case .recovery:
            AutomationCanvasGraph(
                defaultSelectedID: "effect",
                groups: [
                    .init(id: "effect", title: "EFFECT BOUNDARY", x: 0.20, y: 0.08, width: 0.27, height: 0.84, tint: KanameColor.danger),
                    .init(id: "recovery", title: "RECOVERY ROUTES", x: 0.49, y: 0.08, width: 0.49, height: 0.84, tint: KanameColor.external),
                ],
                steps: [
                    .init(id: "each", title: "For each item", subtitle: "Bounded batch", symbol: "repeat", kind: .loop, x: 0.09, y: 0.50, state: .complete, input: "Frozen targets", output: "One target", authority: "No effect"),
                    .init(id: "effect", title: "Apply action", subtitle: "Idempotency key", symbol: "checkmark.shield", kind: .effect, x: 0.33, y: 0.50, state: .running, input: "Exact target", output: "Effect outcome", authority: "Frozen batch approval"),
                    .init(id: "success", title: "Succeeded", subtitle: "Reconcile target", symbol: "checkmark.circle.fill", kind: .receipt, x: 0.60, y: 0.20, state: .complete, input: "Known success", output: "Verified receipt", authority: "Read back"),
                    .init(id: "retry", title: "Retry", subtitle: "Backoff + limit", symbol: "arrow.clockwise", kind: .loop, x: 0.60, y: 0.50, state: .waiting, input: "Known failure", output: "New attempt", authority: "Same approved target"),
                    .init(id: "unknown", title: "Unknown outcome", subtitle: "Never auto-retry", symbol: "questionmark.diamond.fill", kind: .error, x: 0.60, y: 0.80, state: .blocked, input: "Ambiguous result", output: "Attention item", authority: "Effects blocked"),
                    .init(id: "reconcile", title: "Human reconcile", subtitle: "Inspect provider", symbol: "person.crop.circle.badge.exclamationmark", kind: .human, x: 0.87, y: 0.80, state: .waiting, input: "Unknown outcome", output: "Resolved status", authority: "Decision only"),
                    .init(id: "receipt", title: "Batch receipt", subtitle: "Success / skip / fail", symbol: "doc.text.magnifyingglass", kind: .receipt, x: 0.87, y: 0.20, state: .planned, input: "Settled targets", output: "Audit evidence", authority: "Local write"),
                ],
                edges: [
                    .init("each", "effect", label: "target 38", kind: .data, active: true),
                    .init("effect", "success", label: "success", kind: .success, active: false),
                    .init("effect", "retry", label: "known failure", kind: .error, active: true),
                    .init("effect", "unknown", label: "ambiguous", kind: .error, active: false),
                    .init("retry", "effect", label: "attempt 2", kind: .loop, active: true),
                    .init("unknown", "reconcile", label: "needs you", kind: .error, active: false),
                    .init("success", "receipt", label: "verified", kind: .success, active: false),
                    .init("reconcile", "receipt", label: "settled", kind: .conditional, active: false),
                ]
            )
        }
    }
}

private enum AutomationInspectorSection: String, CaseIterable {
    case configuration = "Config"
    case data = "Data"
    case history = "History"
    case safety = "Safety"
}

private enum AutomationEditorMode: String, CaseIterable {
    case canvas = "Canvas"
    case outline = "Outline"
    case source = "Source"
}

private enum AutomationBuilderDesignPanel {
    case standard
    case newWorkflow
    case condition
    case mapping
    case test
    case problems
    case publish
    case storage
    case storagePromotion

    init(arguments: [String]) {
        if arguments.contains("--desktop-automation-builder-new") { self = .newWorkflow }
        else if arguments.contains("--desktop-automation-builder-condition") { self = .condition }
        else if arguments.contains("--desktop-automation-builder-mapping") { self = .mapping }
        else if arguments.contains("--desktop-automation-builder-test") { self = .test }
        else if arguments.contains("--desktop-automation-builder-problems") { self = .problems }
        else if arguments.contains("--desktop-automation-builder-publish") { self = .publish }
        else if arguments.contains("--desktop-automation-builder-storage-promotion") { self = .storagePromotion }
        else if arguments.contains("--desktop-automation-builder-storage") { self = .storage }
        else { self = .standard }
    }
}

private enum AutomationCanvasViewportPreset {
    case standard
    case readable
    case semanticOverview
    case feedbackFocus

    var title: String {
        switch self {
        case .standard: "Stable canvas"
        case .readable: "Readable 100%"
        case .semanticOverview: "Fit all · semantic overview"
        case .feedbackFocus: "Focus · Feedback & correction"
        }
    }

    var zoomLabel: String {
        switch self {
        case .standard: "Fit"
        case .readable: "100%"
        case .semanticOverview: "Fit"
        case .feedbackFocus: "Focus"
        }
    }
}

private enum AutomationCompactBuilderPanel: Equatable {
    case palette
    case inspector
}

private struct AutomationCanvasPreview: View {
    private let workflowID: String
    private let viewportPreset: AutomationCanvasViewportPreset
    private let builderDesignPanel: AutomationBuilderDesignPanel
    private let liveWorkflow: AutomationWorkflowPreview?
    private let liveGraph: AutomationCanvasGraph?
    private let liveRevisions: [DesktopWorkflowRevisionRecord]
    private let liveSourceLines: [String]
    private let editAction: (() -> Void)?
    private let runAction: (() -> Void)?
    private let publishAction: (() -> Void)?
    @State private var pattern: AutomationCanvasPattern
    @State private var selectedStepID: String
    @State private var selectedEdgeID: String?
    @State private var inspectorSection = AutomationInspectorSection.configuration
    @State private var isSimulating = true
    @State private var editorMode: AutomationEditorMode
    @State private var isEditing = false
    @State private var showsVersionHistory = false
    @State private var selectedProblemID: String?
    @State private var diagnosticNavigation = DesktopWorkflowDiagnosticNavigationState()
    @State private var problemFocusMessage: String?
    @State private var problemsExpanded: Bool
    @State private var compactPanel: AutomationCompactBuilderPanel?

    init(workflowID: String) {
        self.workflowID = workflowID
        liveWorkflow = nil
        liveGraph = nil
        liveRevisions = []
        liveSourceLines = []
        editAction = nil
        runAction = nil
        publishAction = nil
        let arguments = CommandLine.arguments
        builderDesignPanel = AutomationBuilderDesignPanel(arguments: arguments)
        if arguments.contains("--desktop-automation-small-readable") {
            viewportPreset = .readable
        } else if arguments.contains("--desktop-automation-small-overview") {
            viewportPreset = .semanticOverview
        } else if arguments.contains("--desktop-automation-small-focus") {
            viewportPreset = .feedbackFocus
        } else if arguments.contains(where: { $0.hasPrefix("--desktop-automation-builder") }) {
            viewportPreset = .readable
        } else {
            viewportPreset = .standard
        }
        let initialPattern: AutomationCanvasPattern
        if arguments.contains("--desktop-automation-small-readable")
            || arguments.contains("--desktop-automation-small-overview")
            || arguments.contains("--desktop-automation-small-focus") {
            initialPattern = .feedback
        } else if arguments.contains("--desktop-automation-canvas-parallel") {
            initialPattern = .parallel
        } else if arguments.contains("--desktop-automation-canvas-approval") {
            initialPattern = .approval
        } else if arguments.contains("--desktop-automation-canvas-feedback") {
            initialPattern = .feedback
        } else if arguments.contains("--desktop-automation-canvas-recovery") {
            initialPattern = .recovery
        } else {
            switch workflowID {
            case "reply-driven": initialPattern = .feedback
            case "correspondence": initialPattern = .approval
            case "approved-cleanup", "filter-management": initialPattern = .recovery
            default: initialPattern = .decision
            }
        }
        _pattern = State(initialValue: initialPattern)
        let initialSelection: String
        switch builderDesignPanel {
        case .condition, .test, .problems: initialSelection = "interpret"
        case .mapping: initialSelection = "context"
        case .storage, .storagePromotion: initialSelection = "execute"
        default: initialSelection = viewportPreset == .feedbackFocus ? "interpret" : initialPattern.graph.defaultSelectedID
        }
        _selectedStepID = State(initialValue: initialSelection)
        _selectedEdgeID = State(initialValue: builderDesignPanel == .condition ? "interpret:correction:append" : nil)
        _inspectorSection = State(initialValue: initialPattern == .feedback ? .history : .configuration)
        if arguments.contains("--desktop-automation-builder-problems-source") {
            _editorMode = State(initialValue: .source)
        } else {
            _editorMode = State(initialValue: arguments.contains("--desktop-automation-outline") ? .outline : .canvas)
        }
        _isEditing = State(initialValue: arguments.contains("--desktop-automation-builder-editing"))
        _showsVersionHistory = State(
            initialValue: arguments.contains("--desktop-automation-builder-versions")
        )
        _selectedProblemID = State(
            initialValue: AutomationWorkflowDiagnosticFixture.presentations.first?.id
        )
        _problemsExpanded = State(
            initialValue: !arguments.contains("--desktop-automation-builder-problems-collapsed")
        )
        _compactPanel = State(initialValue: nil)
    }

    init(
        workflow: AutomationWorkflowPreview,
        graph: AutomationCanvasGraph,
        revisions: [DesktopWorkflowRevisionRecord],
        sourceLines: [String],
        edit: @escaping () -> Void,
        run: (() -> Void)?,
        publish: (() -> Void)? = nil
    ) {
        workflowID = workflow.id
        viewportPreset = .readable
        builderDesignPanel = .standard
        liveWorkflow = workflow
        liveGraph = graph
        liveRevisions = revisions
        liveSourceLines = sourceLines
        editAction = edit
        runAction = run
        publishAction = publish
        _pattern = State(initialValue: .decision)
        _selectedStepID = State(initialValue: graph.defaultSelectedID)
        _selectedEdgeID = State(initialValue: nil)
        _editorMode = State(initialValue: .canvas)
        _isEditing = State(initialValue: false)
        _showsVersionHistory = State(initialValue: false)
        _selectedProblemID = State(initialValue: nil)
        _problemsExpanded = State(initialValue: false)
        _isSimulating = State(initialValue: false)
        _compactPanel = State(initialValue: nil)
    }

    private var isLive: Bool { liveGraph != nil }
    private var graph: AutomationCanvasGraph { liveGraph ?? pattern.graph }
    private var workflow: AutomationWorkflowPreview {
        liveWorkflow
            ?? AutomationWorkflowPreview.portfolio.first(where: { $0.id == workflowID })
            ?? AutomationWorkflowPreview.portfolio[0]
    }
    private var numericVersion: Int { Int(workflow.version.split(separator: ".").first ?? "1") ?? 1 }
    private var nextVersionLabel: String { isLive ? "next version" : "v\(numericVersion + 1)" }
    private var selectedStep: AutomationCanvasStep {
        graph.steps.first(where: { $0.id == selectedStepID })
            ?? graph.steps.first(where: { $0.id == graph.defaultSelectedID })
            ?? graph.steps[0]
    }
    private var selectedDiagnostic: DesktopWorkflowDiagnosticPresentation? {
        AutomationWorkflowDiagnosticFixture.presentations.first { $0.id == selectedProblemID }
    }

    var body: some View {
        Group {
            if builderDesignPanel == .newWorkflow {
                AutomationNewWorkflowDesign()
            } else {
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: 12) {
                        canvasHeader
                        fullCanvasWorkspace
                    }
                    .frame(minWidth: 1_050, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 12) {
                        compactCanvasHeader
                        compactCanvasWorkspace
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 510, alignment: .topLeading)
        .onChange(of: pattern) { newPattern in
            guard !isLive else { return }
            selectedStepID = newPattern.graph.defaultSelectedID
            inspectorSection = newPattern == .feedback ? .history : .configuration
        }
    }

    private var fullCanvasWorkspace: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .top, spacing: 12) {
                AutomationNodePalette(isEditing: isEditing)
                    .frame(width: 178)
                canvasSurface(minimumHeight: builderDesignPanel == .problems ? 390 : 510, compact: false)
                builderInspector
                    .frame(width: 248)
            }
            if builderDesignPanel == .problems {
                problemsDrawer
                    .frame(height: problemsExpanded ? 194 : 46)
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private var builderInspector: some View {
        switch builderDesignPanel {
        case .condition:
            AutomationConditionDesignPanel()
        case .mapping:
            AutomationDataMappingDesignPanel()
        case .test:
            AutomationNodeTestDesignPanel()
        case .publish:
            AutomationPublishReviewDesignPanel(currentVersion: numericVersion)
        case .storage:
            AutomationStorageAccessDesignPanel()
        case .storagePromotion:
            AutomationStoragePromotionDesignPanel()
        case .standard, .problems, .newWorkflow:
            if showsVersionHistory {
                if isLive {
                    AutomationLiveVersionHistoryPanel(revisions: liveRevisions)
                } else {
                    AutomationVersionHistoryPanel(currentVersion: numericVersion)
                }
            } else {
                AutomationNodeInspector(
                    step: selectedStep,
                    section: $inspectorSection,
                    showsCaseHistory: !isLive && pattern == .feedback,
                    isLive: isLive
                )
            }
        }
    }

    private var compactCanvasWorkspace: some View {
        VStack(spacing: 8) {
            if let compactPanel {
                compactPanelContent(compactPanel)
            }
            ZStack(alignment: .bottom) {
                canvasSurface(minimumHeight: 350, compact: true)
                if builderDesignPanel == .problems {
                    problemsDrawer
                        .frame(height: problemsExpanded ? 184 : 46)
                        .padding(8)
                }
            }
            HStack(spacing: 12) {
                Label("Selected: \(selectedStep.title)", systemImage: selectedStep.symbol)
                    .foregroundStyle(selectedStep.kind.tint)
                Divider().frame(height: 16)
                Text("\(selectedStep.input) → \(selectedStep.output)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Label(selectedStep.authority, systemImage: "lock.shield")
                    .foregroundStyle(selectedStep.kind == .effect ? KanameColor.warning : .secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func compactPanelContent(_ panel: AutomationCompactBuilderPanel) -> some View {
        ZStack(alignment: .topTrailing) {
            switch panel {
            case .palette:
                AutomationNodePalette(isEditing: isEditing, showsHeader: false)
            case .inspector:
                builderInspector
            }
            Button {
                compactPanel = nil
            } label: {
                Label("Close panel", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func canvasSurface(minimumHeight: CGFloat, compact: Bool) -> some View {
        VStack(spacing: 8) {
            canvasToolbar(compact: compact)
            Group {
                switch editorMode {
                case .canvas:
                    if builderDesignPanel == .storage || builderDesignPanel == .storagePromotion {
                        AutomationStorageCanvasDesign(
                            mode: builderDesignPanel == .storagePromotion ? .promotion : .scopes
                        )
                    } else {
                        AutomationNodeCanvas(
                            graph: graph,
                            selectedStepID: $selectedStepID,
                            isSimulating: isSimulating,
                            viewportPreset: viewportPreset,
                            selectedEdgeID: $selectedEdgeID,
                            isEditing: isEditing
                        )
                    }
                case .outline:
                    AutomationOutlinePreview(graph: graph, selectedStepID: $selectedStepID)
                case .source:
                    AutomationSourceDiagnosticPreview(
                        diagnostic: selectedDiagnostic,
                        lines: isLive ? liveSourceLines : nil
                    )
                }
            }
            .frame(minHeight: minimumHeight)
            canvasLegend(compact: compact)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(KanameColor.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var problemsDrawer: some View {
        AutomationProblemsDrawer(
            diagnostics: AutomationWorkflowDiagnosticFixture.presentations,
            selectedID: $selectedProblemID,
            isExpanded: $problemsExpanded,
            focusMessage: problemFocusMessage,
            onFocus: focusDiagnostic
        )
    }

    private func focusDiagnostic(_ diagnostic: DesktopWorkflowDiagnosticPresentation) {
        var navigation = diagnosticNavigation
        let outcome = navigation.focus(
            diagnostic,
            availableNodeIDs: Set(graph.steps.map(\.id)),
            availableEdgeIDs: Set(graph.edges.map(\.id))
        )
        diagnosticNavigation = navigation
        selectedProblemID = diagnostic.id
        switch outcome {
        case let .focused(target):
            if let nodeID = target.nodeID { selectedStepID = nodeID }
            selectedEdgeID = target.edgeID
            switch target.projection {
            case .canvas: editorMode = .canvas
            case .outline: editorMode = .outline
            case .source: editorMode = .source
            }
            problemFocusMessage = "Focused \(target.projection.rawValue) at \(target.jsonPointer ?? target.nodeID ?? target.edgeID ?? "declared target")."
        case .targetUnavailable:
            problemFocusMessage = "The declared target is unavailable. The diagnostic remains selected without focusing a different item."
        }
    }

    private var canvasHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.name).font(.title3.weight(.bold))
                HStack(spacing: 7) {
                    Text(isLive ? workflow.summary : pattern.title + " · " + pattern.summary)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(isEditing ? "DRAFT \(nextVersionLabel.uppercased())" : "PUBLISHED v\(workflow.version)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isEditing ? KanameColor.warning : KanameColor.success)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((isEditing ? KanameColor.warning : KanameColor.success).opacity(0.12), in: Capsule())
                }
            }
            Spacer()
            if !isLive {
                Picker("Canvas pattern", selection: $pattern) {
                    ForEach(AutomationCanvasPattern.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 390)
            }
            if let runAction {
                Button("Run…", systemImage: "play.fill", action: runAction)
                    .buttonStyle(.bordered)
            }
            if let publishAction {
                Button("Publish to library", systemImage: "cylinder.split.1x2", action: publishAction)
                    .buttonStyle(.bordered)
                    .help("Converts this workflow to the durable v1 graph and publishes an active revision on the Rust executor")
            }
            Button("Versions", systemImage: "clock.arrow.circlepath") {
                showsVersionHistory.toggle()
            }
            .buttonStyle(.bordered)
            Button(
                isEditing ? "Finish draft" : "Edit as \(nextVersionLabel)",
                systemImage: isEditing ? "checkmark" : "square.and.pencil"
            ) {
                if let editAction { editAction() }
                else {
                    isEditing.toggle()
                    showsVersionHistory = false
                    isSimulating = false
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var compactCanvasHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.name).font(.headline.weight(.bold))
                Text(isEditing ? "DRAFT \(nextVersionLabel.uppercased())" : "PUBLISHED v\(workflow.version)")
                    .font(.caption)
                    .foregroundStyle(isEditing ? KanameColor.warning : .secondary)
            }
            Spacer()
            Button("Add", systemImage: "plus") {
                compactPanel = compactPanel == .palette ? nil : .palette
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Inspect", systemImage: "sidebar.right") {
                compactPanel = compactPanel == .inspector ? nil : .inspector
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if !isEditing {
                Button("Edit", systemImage: "square.and.pencil") {
                    if let editAction { editAction() } else { isEditing = true }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func canvasToolbar(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Picker("Editor", selection: $editorMode) {
                ForEach(AutomationEditorMode.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Divider().frame(height: 18)
            if isEditing {
                Button("Undo", systemImage: "arrow.uturn.backward") {}.buttonStyle(.plain)
                Button("Redo", systemImage: "arrow.uturn.forward") {}.buttonStyle(.plain).disabled(true)
                Label("Draft changes", systemImage: "circle.fill").foregroundStyle(KanameColor.warning)
            } else {
                Text("Preview only · no qualification receipt")
                    .foregroundStyle(KanameColor.warning)
            }
            if !compact {
                Text("\(graph.steps.count) nodes · \(graph.edges.count) connections")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isEditing {
                Button("Discard", role: .destructive) {}.buttonStyle(.plain)
                Button("Publish v7") {}.buttonStyle(.borderedProminent).controlSize(.small).disabled(true)
            } else {
                Button(isSimulating ? "Pause preview" : "Preview run", systemImage: isSimulating ? "pause.fill" : "play.fill") {
                    isSimulating.toggle()
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 7) {
                Image(systemName: "minus.magnifyingglass")
                Text(viewportPreset.zoomLabel)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                Image(systemName: "plus.magnifyingglass")
                Divider().frame(height: 14)
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .help("Fit all")
                Image(systemName: "map")
                    .help("Toggle minimap")
            }
            .foregroundStyle(.secondary)
            if !compact {
                Label(isLive ? "Published" : "Autosaved", systemImage: "checkmark.circle")
                    .foregroundStyle(KanameColor.success)
            }
        }
        .font(.caption)
    }

    private func canvasLegend(compact: Bool) -> some View {
        HStack(spacing: 14) {
            Label("Data", systemImage: "circle.fill").foregroundStyle(KanameColor.accent)
            Label("Decision", systemImage: "circle.fill").foregroundStyle(KanameColor.warning)
            Label("Parallel", systemImage: "circle.fill").foregroundStyle(KanameColor.blocked)
            Label("Effect", systemImage: "circle.fill").foregroundStyle(KanameColor.danger)
            if !compact {
                Label("Error / retry", systemImage: "circle.fill").foregroundStyle(KanameColor.external)
            }
            Spacer()
            if !compact {
                Text(editorMode == .canvas
                    ? (isLive ? "Published graph · open a run to overlay its execution path" : "Animated dashes show the active fixture path")
                    : "Branches remain explicit in incoming and outgoing routes")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }
}

private struct AutomationOutlinePreview: View {
    let graph: AutomationCanvasGraph
    @Binding var selectedStepID: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Node").frame(width: 190, alignment: .leading)
                Text("Incoming").frame(maxWidth: .infinity, alignment: .leading)
                Text("Outgoing").frame(maxWidth: .infinity, alignment: .leading)
                Text("Authority").frame(width: 150, alignment: .leading)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(graph.steps) { step in
                        Button {
                            selectedStepID = step.id
                        } label: {
                            HStack(spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: step.symbol)
                                        .foregroundStyle(step.kind.tint)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(step.title).font(.caption.weight(.semibold))
                                        Text(step.kind.label).font(.system(size: 8, weight: .bold)).foregroundStyle(step.kind.tint)
                                    }
                                }
                                .frame(width: 190, alignment: .leading)
                                routeList(incomingEdges(for: step.id))
                                routeList(outgoingEdges(for: step.id))
                                Text(step.authority)
                                    .font(.caption2)
                                    .foregroundStyle(step.kind == .effect ? KanameColor.warning : .secondary)
                                    .frame(width: 150, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                selectedStepID == step.id ? KanameColor.accent.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
        .background(KanameColor.canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.separator, lineWidth: 1) }
    }

    private func incomingEdges(for stepID: String) -> [AutomationCanvasEdge] {
        graph.edges.filter { $0.targetID == stepID }
    }

    private func outgoingEdges(for stepID: String) -> [AutomationCanvasEdge] {
        graph.edges.filter { $0.sourceID == stepID }
    }

    private func routeList(_ edges: [AutomationCanvasEdge]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if edges.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            } else {
                ForEach(edges) { edge in
                    HStack(spacing: 5) {
                        Circle().fill(edge.kind.tint).frame(width: 6, height: 6)
                        Text(edge.label).lineLimit(1)
                    }
                }
            }
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AutomationSourceDiagnosticPreview: View {
    let diagnostic: DesktopWorkflowDiagnosticPresentation?
    private let lines: [String]

    private static let fixtureLines = [
        "{",
        "  \"schemaVersion\": 1,",
        "  \"graph\": {",
        "    \"entryNodeID\": \"\",",
        "    \"nodes\": [",
        "      { \"id\": \"inbound\", \"type\": \"trigger.email\" },",
        "      { \"id\": \"interpret\", \"type\": \"control.match\" },",
        "      { \"id\": \"append\", \"type\": \"context.append\" },",
        "      { \"id\": \"reply\", \"type\": \"effect.email.reply\" }",
        "    ]",
        "  }",
        "}",
    ]

    init(diagnostic: DesktopWorkflowDiagnosticPresentation?, lines: [String]? = nil) {
        self.diagnostic = diagnostic
        self.lines = lines ?? Self.fixtureLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sourceHeader
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        sourceLine(index: index, text: line)
                    }
                }
            }
            .background(KanameColor.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .background(KanameColor.canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.separator, lineWidth: 1) }
    }

    private var sourceHeader: some View {
        HStack(spacing: 8) {
            Label("workflow.json", systemImage: "doc.text")
                .font(.caption.weight(.semibold))
            if let pointer = diagnostic?.focusTarget.jsonPointer {
                Text(pointer)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(KanameColor.accent)
            }
            Spacer()
            if let range = diagnostic?.focusTarget.sourceRange {
                Text("bytes \(range.start.byteOffset)–\(range.end.byteOffset)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceLine(index: Int, text: String) -> some View {
        let selected = isSelected(index)
        return HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            Text(text)
                .foregroundStyle(selected ? KanameColor.textPrimary : Color.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? KanameColor.danger.opacity(0.18) : Color.clear)
    }

    private func isSelected(_ zeroBasedLine: Int) -> Bool {
        guard let range = diagnostic?.focusTarget.sourceRange else { return false }
        return zeroBasedLine >= Int(range.start.line) && zeroBasedLine <= Int(range.end.line)
    }
}

private struct AutomationNodePalette: View {
    let isEditing: Bool
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                HStack {
                    Text("Add").font(.headline)
                    Spacer()
                    Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("Search nodes and patterns")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(7)
            .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
            paletteSection("START", items: [
                ("Trigger", "bolt.fill"), ("Schedule", "calendar.badge.clock"),
            ])
            paletteSection("PROCESS", items: [
                ("Data", "square.3.layers.3d"), ("Transform", "wand.and.stars"),
                ("AI", "sparkles"), ("Context", "text.append"),
                ("Subflow", "square.stack.3d.up"),
            ])
            paletteSection("FLOW", items: [
                ("Decision", "arrow.triangle.branch"), ("Parallel", "arrow.triangle.2.circlepath"),
                ("Join", "arrow.triangle.merge"), ("Loop", "repeat"),
                ("Wait", "clock.badge"),
            ])
            paletteSection("STORAGE", items: [
                ("Job storage", "shippingbox"), ("Workflow storage", "externaldrive"),
                ("Promote", "arrow.up.doc"),
            ])
            paletteSection("CONTROL", items: [
                ("Human review", "person.crop.circle"), ("Effect", "checkmark.shield"),
                ("Receipt", "doc.text.magnifyingglass"),
            ])
            paletteSection("PATTERNS", items: [
                ("Email feedback", "envelope.arrow.triangle.branch"),
                ("Approval + wait", "person.badge.clock"),
            ])
            Divider()
                .padding(.top, 4)
            Label(
                isEditing ? "Drag or press Return to add" : "Edit to change this graph",
                systemImage: isEditing ? "keyboard" : "lock.fill"
            )
            .font(.caption2)
            .foregroundStyle(isEditing ? KanameColor.accent : .secondary)
        }
        .padding(13)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func paletteSection(_ title: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(items, id: \.0) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.1).frame(width: 14)
                    Text(item.0).lineLimit(1)
                    Spacer(minLength: 0)
                    if isEditing { Image(systemName: "plus.circle").foregroundStyle(KanameColor.accent) }
                }
                .font(.caption.weight(.medium))
                .padding(.vertical, 2)
            }
        }
    }
}

private enum AutomationCanvasNodeKind {
    case trigger
    case data
    case policy
    case decision
    case parallel
    case join
    case loop
    case ai
    case context
    case human
    case wait
    case effect
    case error
    case subflow
    case receipt

    var label: String {
        switch self {
        case .trigger: "TRIGGER"
        case .data: "DATA"
        case .policy: "POLICY"
        case .decision: "DECISION"
        case .parallel: "PARALLEL"
        case .join: "JOIN"
        case .loop: "LOOP"
        case .ai: "AI"
        case .context: "CONTEXT"
        case .human: "HUMAN"
        case .wait: "WAIT"
        case .effect: "EFFECT"
        case .error: "ERROR"
        case .subflow: "SUBFLOW"
        case .receipt: "RECEIPT"
        }
    }

    var tint: Color {
        switch self {
        case .trigger, .data, .policy, .receipt: KanameColor.accent
        case .context: KanameColor.active
        case .decision, .human, .wait: KanameColor.warning
        case .parallel, .join, .loop, .subflow: KanameColor.blocked
        case .ai: KanameColor.active
        case .effect, .error: KanameColor.danger
        }
    }
}

private struct AutomationCanvasStep: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let kind: AutomationCanvasNodeKind
    let x: CGFloat
    let y: CGFloat
    let state: AutomationPreviewState
    let input: String
    let output: String
    let authority: String
    /// Why the compiler keeps this node schema-only, in plain language.
    var availabilityReason: String? = nil
}

private struct AutomationCanvasEdge: Identifiable {
    enum Kind {
        case data
        case conditional
        case success
        case parallel
        case error
        case loop

        var tint: Color {
            switch self {
            case .data: KanameColor.accent
            case .conditional: KanameColor.warning
            case .success: KanameColor.success
            case .parallel: KanameColor.blocked
            case .error: KanameColor.danger
            case .loop: KanameColor.external
            }
        }
    }

    let id: String
    let sourceID: String
    let targetID: String
    let label: String
    let kind: Kind
    let active: Bool

    init(_ sourceID: String, _ targetID: String, label: String, kind: Kind, active: Bool) {
        id = "\(sourceID)-\(targetID)-\(label)"
        self.sourceID = sourceID
        self.targetID = targetID
        self.label = label
        self.kind = kind
        self.active = active
    }
}

private struct AutomationCanvasGroup: Identifiable {
    let id: String
    let title: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let tint: Color
}

private struct AutomationCanvasGraph {
    let defaultSelectedID: String
    let groups: [AutomationCanvasGroup]
    let steps: [AutomationCanvasStep]
    let edges: [AutomationCanvasEdge]

    static func live(
        revision: DesktopWorkflowRevisionRecord,
        availability: [String: LocalCoreRunner.WorkflowNodeAvailabilityDecision] = [:]
    ) -> Self {
        let definitions = revision.steps
        guard !definitions.isEmpty else {
            let empty = AutomationCanvasStep(
                id: "empty", title: "No nodes", subtitle: "Edit this workflow to add its first node",
                symbol: "plus.circle", kind: .data, x: 0.5, y: 0.5, state: .planned,
                input: "No input", output: "No output", authority: "No authority"
            )
            return Self(defaultSelectedID: empty.id, groups: [], steps: [empty], edges: [])
        }

        let ids = Set(definitions.map(\.id))
        var levelByID: [String: Int] = [:]
        let incoming = Dictionary(grouping: definitions.flatMap { step in
            (step.transitions ?? []).map(\.targetStepID).filter { ids.contains($0) }
        }, by: { $0 })
        var queue = definitions.filter { incoming[$0.id] == nil }.map(\.id)
        if queue.isEmpty, let first = definitions.first?.id { queue = [first] }
        for root in queue { levelByID[root] = 0 }
        var cursor = 0
        while cursor < queue.count {
            let sourceID = queue[cursor]
            cursor += 1
            guard let source = definitions.first(where: { $0.id == sourceID }) else { continue }
            let nextLevel = (levelByID[sourceID] ?? 0) + 1
            for target in (source.transitions ?? []).map(\.targetStepID) where ids.contains(target) {
                guard levelByID[target] == nil else { continue }
                levelByID[target] = nextLevel
                queue.append(target)
            }
        }
        var fallbackLevel = (levelByID.values.max() ?? -1) + 1
        for step in definitions where levelByID[step.id] == nil {
            levelByID[step.id] = fallbackLevel
            fallbackLevel += 1
        }
        let maximumLevel = max(1, levelByID.values.max() ?? 1)
        let byLevel = Dictionary(grouping: definitions, by: { levelByID[$0.id] ?? 0 })
        let nodes = definitions.map { step -> AutomationCanvasStep in
            let level = levelByID[step.id] ?? 0
            let peers = byLevel[level] ?? [step]
            let row = peers.firstIndex(where: { $0.id == step.id }) ?? 0
            let y = peers.count == 1 ? 0.5 : 0.14 + (0.72 * CGFloat(row) / CGFloat(peers.count - 1))
            return AutomationCanvasStep(
                id: step.id,
                title: step.name,
                subtitle: step.kind.label,
                symbol: step.kind.automationSymbol,
                kind: step.kind.automationKind,
                x: 0.08 + (0.84 * CGFloat(level) / CGFloat(maximumLevel)),
                y: y,
                state: availability[step.id].map { $0.isExecutable ? .executable : .schemaOnly } ?? .planned,
                input: step.inputSchemaReference ?? "\(step.inputMappings?.count ?? 0) mapped inputs",
                output: step.outputSchemaReference ?? "Typed output",
                authority: step.automationAuthority,
                availabilityReason: availability[step.id].flatMap(\.downgradeCondition)
                    .map(DesktopWorkflowDowngradeConditionPresentation.text(for:))
            )
        }
        var connections = definitions.flatMap { source in
            (source.transitions ?? []).filter { ids.contains($0.targetStepID) }.map { transition in
                AutomationCanvasEdge(
                    source.id,
                    transition.targetStepID,
                    label: transition.outcome.rawValue,
                    kind: transition.outcome.automationEdgeKind,
                    active: false
                )
            }
        }
        if connections.isEmpty, definitions.count > 1 {
            connections = zip(definitions, definitions.dropFirst()).map { source, target in
                AutomationCanvasEdge(source.id, target.id, label: "next", kind: .data, active: false)
            }
        }
        return Self(
            defaultSelectedID: definitions[0].id,
            groups: [
                .init(
                    id: "published", title: "PUBLISHED REVISION \(revision.version)",
                    x: 0.015, y: 0.05, width: 0.97, height: 0.90, tint: KanameColor.accent
                ),
            ],
            steps: nodes,
            edges: connections
        )
    }

    func sourceLines(workflow: AutomationWorkflowPreview) -> [String] {
        let escapedName = workflow.name.replacingOccurrences(of: "\"", with: "\\\"")
        var result = [
            "{",
            "  \"id\": \"\(workflow.id)\",",
            "  \"name\": \"\(escapedName)\",",
            "  \"version\": \"\(workflow.version)\",",
            "  \"nodes\": [",
        ]
        for (index, step) in steps.enumerated() {
            let suffix = index == steps.count - 1 ? "" : ","
            result.append("    { \"id\": \"\(step.id)\", \"type\": \"\(step.kind.label.lowercased())\" }\(suffix)")
        }
        result += ["  ],", "  \"connections\": \(edges.count)", "}"]
        return result
    }

}

private extension DesktopWorkflowStepKind {
    var automationKind: AutomationCanvasNodeKind {
        switch self {
        case .classifyEvent: .trigger
        case .correlateWork, .branch, .match: .decision
        case .compileContext: .context
        case .structuredModel, .agent: .ai
        case .invokeTool: .subflow
        case .registerArtifact: .data
        case .validate: .policy
        case .forEach: .loop
        case .effect, .sendEmail: .effect
        case .humanReview, .requestApproval: .human
        case .createEmailDraft: .data
        case .waitForEmail: .wait
        case .complete: .receipt
        }
    }

    var automationSymbol: String {
        switch self {
        case .classifyEvent: "bolt.fill"
        case .correlateWork: "link"
        case .compileContext: "text.append"
        case .structuredModel: "sparkles"
        case .invokeTool: "wrench.and.screwdriver"
        case .registerArtifact: "doc.badge.plus"
        case .validate: "checkmark.seal"
        case .branch: "arrow.triangle.branch"
        case .match: "arrow.triangle.swap"
        case .forEach: "repeat"
        case .agent: "cpu"
        case .effect: "checkmark.shield"
        case .humanReview: "person.crop.circle"
        case .requestApproval: "person.crop.circle.badge.checkmark"
        case .createEmailDraft: "square.and.pencil"
        case .sendEmail: "paperplane.fill"
        case .waitForEmail: "clock.badge"
        case .complete: "checkmark.circle.fill"
        }
    }
}

private extension DesktopWorkflowStepDefinition {
    var automationAuthority: String {
        switch kind {
        case .effect: "Trusted connector approval"
        case .sendEmail: "Exact send approval"
        case .createEmailDraft: "Draft only"
        case .humanReview, .requestApproval: "Human decision"
        case .waitForEmail, .classifyEvent: "Observe only"
        case .structuredModel, .agent: "Declared model egress"
        default: "No external effect"
        }
    }
}

private extension DesktopWorkflowTransitionOutcome {
    var automationEdgeKind: AutomationCanvasEdge.Kind {
        switch self {
        case .matched, .approved, .selected, .acknowledged, .succeeded: .success
        case .notMatched, .rejected, .edited, .timedOut, .cancelled: .conditional
        case .failed: .error
        case .always: .data
        }
    }
}

private struct AutomationNodeCanvas: View {
    let graph: AutomationCanvasGraph
    @Binding var selectedStepID: String
    let isSimulating: Bool
    var viewportPreset: AutomationCanvasViewportPreset = .standard
    var selectedEdgeID: Binding<String?>? = nil
    var isEditing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let worldSize = CGSize(width: 1_320, height: 620)

    private struct ViewportLayout {
        let scale: CGFloat
        let offset: CGPoint
        let semanticOverview: Bool
        let showsMinimap: Bool

        func position(x: CGFloat, y: CGFloat, worldSize: CGSize) -> CGPoint {
            CGPoint(
                x: x * worldSize.width * scale + offset.x,
                y: y * worldSize.height * scale + offset.y
            )
        }

        func visibleWorldRect(viewportSize: CGSize, worldSize: CGSize) -> CGRect {
            CGRect(
                x: -offset.x / scale,
                y: -offset.y / scale,
                width: viewportSize.width / scale,
                height: viewportSize.height / scale
            )
            .intersection(CGRect(origin: .zero, size: worldSize))
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = viewportLayout(in: proxy.size)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isSimulating)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
                ZStack {
                    ForEach(graph.groups) { group in
                        AutomationCanvasGroupView(group: group)
                            .frame(
                                width: group.width * worldSize.width * layout.scale,
                                height: group.height * worldSize.height * layout.scale
                            )
                            .position(layout.position(
                                x: group.x + group.width / 2,
                                y: group.y + group.height / 2,
                                worldSize: worldSize
                            ))
                    }

                    Canvas { context, size in
                        drawEdges(context: &context, size: size, phase: phase, layout: layout)
                    }

                    ForEach(graph.edges) { edge in
                        if let position = edgeLabelPosition(edge, size: proxy.size, layout: layout) {
                            if let selectedEdgeID {
                                Button {
                                    selectedEdgeID.wrappedValue = edge.id
                                } label: {
                                    edgeLabel(edge, selected: selectedEdgeID.wrappedValue == edge.id)
                                }
                                .buttonStyle(.plain)
                                .position(position)
                            } else {
                                edgeLabel(edge, selected: false)
                                    .position(position)
                            }
                        }
                    }

                    ForEach(graph.steps) { step in
                        Button {
                            selectedStepID = step.id
                            selectedEdgeID?.wrappedValue = nil
                        } label: {
                            if layout.semanticOverview {
                                AutomationSemanticNodeCard(
                                    step: step,
                                    selected: selectedStepID == step.id
                                )
                            } else {
                                AutomationNodeCard(
                                    step: step,
                                    selected: selectedStepID == step.id,
                                    animated: isSimulating && step.state == .running && !reduceMotion,
                                    phase: phase,
                                    collapsedSubflow: viewportPreset == .feedbackFocus && step.id == "execute"
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .position(layout.position(x: step.x, y: step.y, worldSize: worldSize))
                    }

                    if isEditing, let firstEdge = graph.edges.first,
                       let position = edgeLabelPosition(firstEdge, size: proxy.size, layout: layout) {
                        Button {
                            selectedEdgeID?.wrappedValue = firstEdge.id
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(KanameColor.canvas)
                                .frame(width: 20, height: 20)
                                .background(KanameColor.accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Insert a compatible node on this connection")
                        .position(x: position.x, y: position.y + 24)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Label(viewportPreset.title, systemImage: viewportSymbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(KanameColor.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(KanameColor.canvas.opacity(0.94), in: Capsule())
                    .overlay { Capsule().stroke(KanameColor.accent.opacity(0.35), lineWidth: 1) }
                    .padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                if layout.showsMinimap {
                    AutomationCanvasMinimap(
                        graph: graph,
                        worldSize: worldSize,
                        visibleWorldRect: layout.visibleWorldRect(
                            viewportSize: proxy.size,
                            worldSize: worldSize
                        )
                    )
                    .padding(10)
                }
            }
        }
        .background { AutomationDotGrid() }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.separator, lineWidth: 1) }
    }

    private var viewportSymbol: String {
        switch viewportPreset {
        case .standard: "viewfinder"
        case .readable: "text.magnifyingglass"
        case .semanticOverview: "arrow.down.right.and.arrow.up.left"
        case .feedbackFocus: "scope"
        }
    }

    private func viewportLayout(in size: CGSize) -> ViewportLayout {
        let fittedScale = min(
            (size.width - 44) / worldSize.width,
            (size.height - 40) / worldSize.height
        )

        switch viewportPreset {
        case .standard:
            let scale = min(1, fittedScale)
            return centeredLayout(scale: scale, size: size, semanticOverview: false, showsMinimap: false)
        case .semanticOverview:
            return centeredLayout(
                scale: min(1, fittedScale),
                size: size,
                semanticOverview: true,
                showsMinimap: false
            )
        case .readable:
            let scale: CGFloat = 1
            let selectedStep = graph.steps.first(where: { $0.id == selectedStepID })
                ?? graph.steps.first(where: { $0.id == graph.defaultSelectedID })
            let focusX = graph.defaultSelectedID == "fanout" && selectedStepID == "fanout"
                ? 0.52
                : (selectedStep?.x ?? 0.5)
            let target = CGPoint(
                x: focusX * worldSize.width,
                y: (selectedStep?.y ?? 0.5) * worldSize.height
            )
            return ViewportLayout(
                scale: scale,
                offset: CGPoint(x: size.width / 2 - target.x, y: size.height / 2 - target.y),
                semanticOverview: false,
                showsMinimap: true
            )
        case .feedbackFocus:
            let focusRect = CGRect(
                x: worldSize.width * 0.32,
                y: worldSize.height * 0.16,
                width: worldSize.width * 0.66,
                height: worldSize.height * 0.78
            )
            let scale = min(
                (size.width - 54) / focusRect.width,
                (size.height - 46) / focusRect.height,
                1
            )
            return ViewportLayout(
                scale: scale,
                offset: CGPoint(
                    x: size.width / 2 - focusRect.midX * scale - 78,
                    y: size.height / 2 - focusRect.midY * scale
                ),
                semanticOverview: false,
                showsMinimap: true
            )
        }
    }

    private func centeredLayout(
        scale: CGFloat,
        size: CGSize,
        semanticOverview: Bool,
        showsMinimap: Bool
    ) -> ViewportLayout {
        ViewportLayout(
            scale: scale,
            offset: CGPoint(
                x: (size.width - worldSize.width * scale) / 2,
                y: (size.height - worldSize.height * scale) / 2
            ),
            semanticOverview: semanticOverview,
            showsMinimap: showsMinimap
        )
    }

    private func edgeLabel(_ edge: AutomationCanvasEdge, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(edge.kind.tint).frame(width: 5, height: 5)
            Text(edge.label)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(edge.kind.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(selected ? edge.kind.tint.opacity(0.22) : KanameColor.canvas.opacity(0.94), in: Capsule())
        .overlay {
            if selected { Capsule().stroke(edge.kind.tint, lineWidth: 1.5) }
        }
        .help("Inspect data checkpoint")
    }

    private func drawEdges(
        context: inout GraphicsContext,
        size: CGSize,
        phase: Double,
        layout: ViewportLayout
    ) {
        for edge in graph.edges {
            guard let source = graph.steps.first(where: { $0.id == edge.sourceID }),
                  let target = graph.steps.first(where: { $0.id == edge.targetID }) else { continue }
            let route = edgeRoute(edge: edge, source: source, target: target, size: size, layout: layout)
            let selected = selectedEdgeID?.wrappedValue == edge.id
            let tint = selected || edge.active ? edge.kind.tint : KanameColor.separator
            context.stroke(
                route.path,
                with: .color(tint),
                style: StrokeStyle(
                    lineWidth: selected ? 4 : (edge.active ? 2.5 : 1.5),
                    dash: edge.active ? [7, 6] : [],
                    dashPhase: edge.active && isSimulating && !reduceMotion ? -phase * 28 : 0
                )
            )
            drawArrowhead(context: &context, tip: route.end, tangentFrom: route.control2, tint: tint)
        }
    }

    private func edgeRoute(
        edge: AutomationCanvasEdge,
        source: AutomationCanvasStep,
        target: AutomationCanvasStep,
        size: CGSize,
        layout: ViewportLayout
    ) -> (path: Path, end: CGPoint, control2: CGPoint) {
        let sourceCenter = layout.position(x: source.x, y: source.y, worldSize: worldSize)
        let targetCenter = layout.position(x: target.x, y: target.y, worldSize: worldSize)
        let deltaX = targetCenter.x - sourceCenter.x
        let deltaY = targetCenter.y - sourceCenter.y
        let nodeHalfWidth: CGFloat = layout.semanticOverview ? 52 : 77
        let nodeHalfHeight: CGFloat = layout.semanticOverview ? 25 : 36
        var path = Path()

        if edge.kind == .loop {
            if abs(deltaX) < 44 {
                let start = CGPoint(x: sourceCenter.x - nodeHalfWidth, y: sourceCenter.y)
                let end = CGPoint(x: targetCenter.x - nodeHalfWidth, y: targetCenter.y)
                let loopX = max(14, min(start.x, end.x) - 64)
                let control1 = CGPoint(x: loopX, y: start.y)
                let control2 = CGPoint(x: loopX, y: end.y)
                path.move(to: start)
                path.addCurve(to: end, control1: control1, control2: control2)
                return (path, end, control2)
            }

            let start = CGPoint(x: sourceCenter.x + nodeHalfWidth, y: sourceCenter.y)
            let end = CGPoint(x: targetCenter.x - nodeHalfWidth, y: targetCenter.y)
            let loopY = min(size.height - 12, max(start.y, end.y) + 72)
            let control1 = CGPoint(x: start.x + 46, y: loopY)
            let control2 = CGPoint(x: end.x - 46, y: loopY)
            path.move(to: start)
            path.addCurve(to: end, control1: control1, control2: control2)
            return (path, end, control2)
        }

        if abs(deltaX) >= abs(deltaY) {
            let direction: CGFloat = deltaX >= 0 ? 1 : -1
            let start = CGPoint(x: sourceCenter.x + direction * nodeHalfWidth, y: sourceCenter.y)
            let end = CGPoint(x: targetCenter.x - direction * nodeHalfWidth, y: targetCenter.y)
            let bend = max(22, abs(end.x - start.x) * 0.45)
            let control1 = CGPoint(x: start.x + direction * bend, y: start.y)
            let control2 = CGPoint(x: end.x - direction * bend, y: end.y)
            path.move(to: start)
            path.addCurve(to: end, control1: control1, control2: control2)
            return (path, end, control2)
        }

        let direction: CGFloat = deltaY >= 0 ? 1 : -1
        let start = CGPoint(x: sourceCenter.x, y: sourceCenter.y + direction * nodeHalfHeight)
        let end = CGPoint(x: targetCenter.x, y: targetCenter.y - direction * nodeHalfHeight)
        let bend = max(18, abs(end.y - start.y) * 0.45)
        let control1 = CGPoint(x: start.x, y: start.y + direction * bend)
        let control2 = CGPoint(x: end.x, y: end.y - direction * bend)
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        return (path, end, control2)
    }

    private func drawArrowhead(
        context: inout GraphicsContext,
        tip: CGPoint,
        tangentFrom: CGPoint,
        tint: Color
    ) {
        let angle = atan2(tip.y - tangentFrom.y, tip.x - tangentFrom.x)
        let length: CGFloat = 8
        let width: CGFloat = 4.5
        let base = CGPoint(x: tip.x - cos(angle) * length, y: tip.y - sin(angle) * length)
        let perpendicular = CGPoint(x: -sin(angle) * width, y: cos(angle) * width)
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: base.x + perpendicular.x, y: base.y + perpendicular.y))
        arrow.addLine(to: CGPoint(x: base.x - perpendicular.x, y: base.y - perpendicular.y))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(tint))
    }

    private func edgeLabelPosition(
        _ edge: AutomationCanvasEdge,
        size: CGSize,
        layout: ViewportLayout
    ) -> CGPoint? {
        guard let source = graph.steps.first(where: { $0.id == edge.sourceID }),
              let target = graph.steps.first(where: { $0.id == edge.targetID }) else { return nil }
        let sourcePosition = layout.position(x: source.x, y: source.y, worldSize: worldSize)
        let targetPosition = layout.position(x: target.x, y: target.y, worldSize: worldSize)
        if edge.kind == .loop, abs(target.x - source.x) < 0.06 {
            return CGPoint(
                x: max(54, sourcePosition.x - 92),
                y: (sourcePosition.y + targetPosition.y) * 0.5
            )
        }
        if edge.kind == .loop || target.x < source.x {
            return CGPoint(
                x: (sourcePosition.x + targetPosition.x) * 0.5,
                y: min(size.height - 16, max(sourcePosition.y, targetPosition.y) + 34)
            )
        }
        if abs(target.y - source.y) < 0.05 {
            return CGPoint(
                x: (sourcePosition.x + targetPosition.x) * 0.5,
                y: sourcePosition.y - 48
            )
        }
        if abs(target.y - source.y) > abs(target.x - source.x) {
            return CGPoint(
                x: (sourcePosition.x + targetPosition.x) * 0.5 + 18,
                y: (sourcePosition.y + targetPosition.y) * 0.5
            )
        }
        return CGPoint(
            x: (sourcePosition.x + targetPosition.x) * 0.5,
            y: (sourcePosition.y + targetPosition.y) * 0.5 - 10
        )
    }
}

private struct AutomationCanvasMinimap: View {
    let graph: AutomationCanvasGraph
    let worldSize: CGSize
    let visibleWorldRect: CGRect

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Map", systemImage: "map")
                Spacer()
                Text("drag viewport")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 9, weight: .bold))

            Canvas { context, size in
                let scaleX = size.width / worldSize.width
                let scaleY = size.height / worldSize.height
                for edge in graph.edges {
                    guard let source = graph.steps.first(where: { $0.id == edge.sourceID }),
                          let target = graph.steps.first(where: { $0.id == edge.targetID }) else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: source.x * size.width, y: source.y * size.height))
                    path.addLine(to: CGPoint(x: target.x * size.width, y: target.y * size.height))
                    context.stroke(path, with: .color(edge.kind.tint.opacity(0.45)), lineWidth: 1)
                }
                for step in graph.steps {
                    let rect = CGRect(
                        x: step.x * size.width - 3,
                        y: step.y * size.height - 2,
                        width: 6,
                        height: 4
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(step.kind.tint))
                }
                let viewportRect = CGRect(
                    x: visibleWorldRect.minX * scaleX,
                    y: visibleWorldRect.minY * scaleY,
                    width: visibleWorldRect.width * scaleX,
                    height: visibleWorldRect.height * scaleY
                )
                context.fill(Path(viewportRect), with: .color(KanameColor.accent.opacity(0.12)))
                context.stroke(Path(viewportRect), with: .color(KanameColor.accent), lineWidth: 1.5)
            }
            .frame(height: 64)
            .background(KanameColor.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(8)
        .frame(width: 170)
        .background(KanameColor.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(KanameColor.separator, lineWidth: 1) }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

private struct AutomationSemanticNodeCard: View {
    let step: AutomationCanvasStep
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: step.symbol)
                .foregroundStyle(step.kind.tint)
            Text(step.title)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
            Circle().fill(step.state.tint).frame(width: 5, height: 5)
        }
        .padding(.horizontal, 8)
        .frame(width: 104, height: 50, alignment: .leading)
        .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? KanameColor.accent : step.kind.tint.opacity(0.45), lineWidth: selected ? 2 : 1)
        }
    }
}

private struct AutomationCanvasGroupView: View {
    let group: AutomationCanvasGroup

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(group.tint.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(group.tint.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
            .overlay(alignment: .topLeading) {
                Text(group.title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(group.tint.opacity(0.85))
                    .padding(8)
            }
    }
}

private struct AutomationDotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 18
            for x in stride(from: spacing, to: size.width, by: spacing) {
                for y in stride(from: spacing, to: size.height, by: spacing) {
                    let rect = CGRect(x: x, y: y, width: 1.4, height: 1.4)
                    context.fill(Path(ellipseIn: rect), with: .color(KanameColor.separator.opacity(0.7)))
                }
            }
        }
        .background(KanameColor.canvas.opacity(0.55))
    }
}

private struct AutomationNodeCard: View {
    let step: AutomationCanvasStep
    let selected: Bool
    let animated: Bool
    let phase: Double
    var collapsedSubflow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.kind.label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(step.kind.tint)
            HStack(spacing: 7) {
                Image(systemName: step.symbol).foregroundStyle(step.kind.tint)
                Text(step.title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Circle().fill(step.state.tint).frame(width: 6, height: 6)
            }
            Text(step.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if collapsedSubflow {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack")
                    Text("5 internal steps collapsed")
                }
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(KanameColor.blocked)
            }
        }
        .padding(10)
        .frame(width: 154, alignment: .leading)
        .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    selected ? KanameColor.accent : step.kind.tint.opacity(step.state == .running ? 0.9 : 0.30),
                    lineWidth: selected || step.state == .running ? 2 : 1
                )
        }
        .shadow(color: step.kind.tint.opacity(animated ? 0.16 + sin(phase * .pi * 2) * 0.10 : 0), radius: 8)
    }
}

private enum AutomationStorageCanvasMode {
    case scopes
    case promotion
}

private struct AutomationStorageCanvasDesign: View {
    let mode: AutomationStorageCanvasMode

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let leftX = max(84, width * 0.17)
            let middleX = width * 0.50
            let rightX = min(width - 84, width * 0.83)
            let jobStorageWidth = min(360, width - 80)
            let workflowStorageWidth = min(410, width - 56)

            ZStack {
                AutomationDotGrid()

                RoundedRectangle(cornerRadius: 14)
                    .fill(KanameColor.accent.opacity(0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(KanameColor.accent.opacity(0.42), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    }
                    .frame(width: width - 24, height: 310)
                    .position(x: width / 2, y: 167)

                Canvas { context, _ in
                    drawStorageConnections(
                        context: &context,
                        leftX: leftX,
                        middleX: middleX,
                        rightX: rightX
                    )
                }

                HStack(spacing: 6) {
                    Image(systemName: "shippingbox.fill")
                    Text("JOB BOUNDARY · RUN #184")
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(KanameColor.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(KanameColor.canvas.opacity(0.94), in: Capsule())
                .position(x: 112, y: 26)

                AutomationStorageProcessCard(
                    title: "Compile context",
                    subtitle: "Build bounded input",
                    symbol: "text.append",
                    access: "READS BOTH"
                )
                .position(x: leftX, y: 100)

                AutomationStorageProcessCard(
                    title: "Run work type",
                    subtitle: "Create revision",
                    symbol: "square.stack.3d.up",
                    access: "JOB READ + WRITE",
                    selected: mode == .scopes
                )
                .position(x: middleX, y: 100)

                AutomationStorageProcessCard(
                    title: "Verify all",
                    subtitle: "Validate output",
                    symbol: "checkmark.seal",
                    access: "JOB READ"
                )
                .position(x: rightX, y: 100)

                AutomationStorageResourceCard(
                    title: "Job storage · #184",
                    subtitle: "Visible only inside this job · survives waits and restarts",
                    symbol: "shippingbox.fill",
                    tint: KanameColor.accent,
                    facts: ["7 values", "3 files", "48.2 MB", "Deletes with job"],
                    width: jobStorageWidth,
                    selected: mode == .scopes
                )
                .position(x: middleX, y: 244)

                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.doc.fill")
                    Text(mode == .promotion ? "PROMOTE · SELECTED" : "EXPLICIT PROMOTION ONLY")
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(mode == .promotion ? KanameColor.warning : KanameColor.blocked)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(KanameColor.canvas, in: Capsule())
                .overlay {
                    Capsule().stroke(
                        mode == .promotion ? KanameColor.warning : KanameColor.blocked.opacity(0.55),
                        lineWidth: mode == .promotion ? 2 : 1
                    )
                }
                .position(x: middleX, y: 350)

                AutomationStorageResourceCard(
                    title: "Workflow storage · Reply-driven reporting",
                    subtitle: "Isolated installation storage · durable across jobs and versions",
                    symbol: "externaldrive.fill",
                    tint: KanameColor.blocked,
                    facts: ["templates/", "cases/", "86 MB", "Explicit lifecycle"],
                    width: workflowStorageWidth,
                    selected: mode == .promotion
                )
                .position(x: middleX, y: 438)

                Label("Workflow storage is outside the job deletion boundary", systemImage: "lock.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .position(x: middleX, y: 500)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.separator, lineWidth: 1) }
    }

    private func drawStorageConnections(
        context: inout GraphicsContext,
        leftX: CGFloat,
        middleX: CGFloat,
        rightX: CGFloat
    ) {
        var flow = Path()
        flow.move(to: CGPoint(x: leftX + 72, y: 100))
        flow.addLine(to: CGPoint(x: middleX - 72, y: 100))
        flow.move(to: CGPoint(x: middleX + 72, y: 100))
        flow.addLine(to: CGPoint(x: rightX - 72, y: 100))
        context.stroke(flow, with: .color(KanameColor.accent), style: StrokeStyle(lineWidth: 2.2, dash: [7, 6]))

        var jobAccess = Path()
        for x in [leftX, middleX, rightX] {
            jobAccess.move(to: CGPoint(x: x, y: 142))
            jobAccess.addCurve(
                to: CGPoint(x: middleX + (x - middleX) * 0.38, y: 198),
                control1: CGPoint(x: x, y: 170),
                control2: CGPoint(x: middleX + (x - middleX) * 0.38, y: 174)
            )
        }
        context.stroke(jobAccess, with: .color(KanameColor.accent.opacity(0.78)), style: StrokeStyle(lineWidth: 1.7, dash: [4, 5]))

        var promotion = Path()
        promotion.move(to: CGPoint(x: middleX, y: 290))
        promotion.addLine(to: CGPoint(x: middleX, y: 397))
        context.stroke(
            promotion,
            with: .color(mode == .promotion ? KanameColor.warning : KanameColor.blocked.opacity(0.65)),
            style: StrokeStyle(lineWidth: mode == .promotion ? 3 : 1.8, dash: mode == .promotion ? [7, 5] : [4, 6])
        )
    }
}

private struct AutomationStorageProcessCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let access: String
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(KanameColor.accent)
                Text(title).font(.caption.weight(.bold)).lineLimit(1)
            }
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(access)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(KanameColor.accent)
        }
        .padding(10)
        .frame(width: 148, height: 84, alignment: .leading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? KanameColor.accent : KanameColor.separator, lineWidth: selected ? 2 : 1)
        }
    }
}

private struct AutomationStorageResourceCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let facts: [String]
    let width: CGFloat
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.bold)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                ForEach(facts, id: \.self) { fact in
                    Text(fact)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(fact.contains("Deletes") ? KanameColor.warning : tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.09), in: Capsule())
                }
            }
        }
        .padding(11)
        .frame(width: width, height: 92, alignment: .leading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? tint : KanameColor.separator, lineWidth: selected ? 2 : 1)
        }
    }
}

private struct AutomationNewWorkflowDesign: View {
    private enum StarterSection: String, CaseIterable {
        case patterns = "Patterns"
        case workflows = "My workflows"
        case source = "Source"

        var symbol: String {
            switch self {
            case .patterns: "square.grid.2x2.fill"
            case .workflows: "doc.on.doc"
            case .source: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    let workflows: [DesktopWorkflowDefinitionRecord]
    let message: String?
    let onUseTemplate: ((AutomationWorkflowStarterTemplate) -> Void)?
    let onDuplicate: ((DesktopWorkflowDefinitionRecord) -> Void)?
    let onImportSource: ((String) -> Bool)?
    let onCancel: (() -> Void)?
    @State private var section = StarterSection.patterns
    @State private var search = ""
    @State private var selectedTemplateID = AutomationWorkflowStarterTemplate.patterns[0].id
    @State private var sourceText: String
    @State private var sourceMessage: String?

    init(
        workflows: [DesktopWorkflowDefinitionRecord] = [],
        message: String? = nil,
        onUseTemplate: ((AutomationWorkflowStarterTemplate) -> Void)? = nil,
        onDuplicate: ((DesktopWorkflowDefinitionRecord) -> Void)? = nil,
        onImportSource: ((String) -> Bool)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.workflows = workflows
        self.message = message
        self.onUseTemplate = onUseTemplate
        self.onDuplicate = onDuplicate
        self.onImportSource = onImportSource
        self.onCancel = onCancel
        _sourceText = State(initialValue: DesktopWorkflowStudioScaffold.blankSource)
    }

    private var visibleTemplates: [AutomationWorkflowStarterTemplate] {
        AutomationWorkflowStarterTemplate.patterns.filter {
            search.isEmpty
                || $0.title.localizedCaseInsensitiveContains(search)
                || $0.summary.localizedCaseInsensitiveContains(search)
        }
    }

    private var visibleWorkflows: [DesktopWorkflowDefinitionRecord] {
        workflows.filter {
            search.isEmpty
                || $0.name.localizedCaseInsensitiveContains(search)
                || $0.summary.localizedCaseInsensitiveContains(search)
        }
    }

    private var selectedTemplate: AutomationWorkflowStarterTemplate {
        AutomationWorkflowStarterTemplate.patterns.first { $0.id == selectedTemplateID }
            ?? AutomationWorkflowStarterTemplate.patterns[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create workflow").font(.title2.weight(.bold))
                    Text("Begin with a proven pattern, duplicate a version, or start from a typed trigger.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onCancel?() }
                    .buttonStyle(.bordered)
                    .disabled(onCancel == nil)
            }

            HStack(spacing: 12) {
                Picker("Starting point", selection: $section) {
                    ForEach(StarterSection.allCases, id: \.self) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 500)
                Spacer()
                if section != .source {
                    TextField(section == .patterns ? "Search patterns" : "Search workflows", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(KanameColor.warning)
            }

            starterContent
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 520, alignment: .topLeading)
        .background(KanameColor.canvas)
    }

    @ViewBuilder
    private var starterContent: some View {
        switch section {
        case .patterns:
            patternContent
        case .workflows:
            workflowContent
        case .source:
            sourceContent
        }
    }

    private var patternContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(visibleTemplates) { template in
                    Button {
                        selectedTemplateID = template.id
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: template.symbol)
                                    .foregroundStyle(template.tint)
                                    .frame(width: 30, height: 30)
                                    .background(template.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                Spacer()
                                Image(systemName: selectedTemplateID == template.id
                                    ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedTemplateID == template.id ? template.tint : .secondary)
                            }
                            Text(template.title).font(.headline)
                            Text(template.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 32, alignment: .topLeading)
                            Divider()
                            HStack {
                                Label("\(template.steps.count) nodes", systemImage: "point.3.connected.trianglepath.dotted")
                                Spacer()
                                Text(template.triggerKinds.map(\.label).joined(separator: " + "))
                            }
                            .font(.caption2.weight(.semibold))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedTemplateID == template.id ? template.tint : KanameColor.separator,
                                        lineWidth: selectedTemplateID == template.id ? 2 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Selects this editable workflow pattern")
                }
            }

            HStack {
                Label("Patterns create ordinary editable drafts; every block and connection can be changed.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Create draft from \(selectedTemplate.title)", systemImage: "arrow.right") {
                    onUseTemplate?(selectedTemplate)
                }
                .buttonStyle(.borderedProminent)
                .disabled(onUseTemplate == nil)
            }
            .font(.caption)
        }
    }

    private var workflowContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Duplicate a published version into a new local workflow. The original remains unchanged.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if visibleWorkflows.isEmpty {
                BoundaryCallout(
                    title: workflows.isEmpty ? "No published workflows yet" : "No matching workflows",
                    detail: workflows.isEmpty
                        ? "Choose a pattern or source to create the first workflow."
                        : "Clear the search to see all published workflows."
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(visibleWorkflows) { workflow in
                    HStack(spacing: 12) {
                        Image(systemName: workflow.icon)
                            .foregroundStyle(KanameColor.accent)
                            .frame(width: 32, height: 32)
                            .background(KanameColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(workflow.name).font(.headline)
                            Text(workflow.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(workflow.triggerKinds.map(\.label).joined(separator: " + "))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Duplicate", systemImage: "doc.on.doc") { onDuplicate?(workflow) }
                            .disabled(onDuplicate == nil)
                    }
                    .padding(14)
                    .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Canonical workflow source").font(.headline)
                    Text("Paste or edit the complete manifest. A successful import opens the exact same canvas and outline draft.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset example") {
                    sourceText = DesktopWorkflowStudioScaffold.blankSource
                    sourceMessage = nil
                }
            }
            WorkflowJSONSourceEditor(
                text: $sourceText,
                minimumHeight: 330,
                accessibilityLabel: "Canonical workflow source"
            )
            if let sourceMessage {
                Label(sourceMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(KanameColor.warning)
            }
            HStack {
                Label("Import is bounded, schema-validated, and capability-checked.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Validate and open draft", systemImage: "arrow.right") {
                    guard let onImportSource else { return }
                    sourceMessage = onImportSource(sourceText)
                        ? nil
                        : "Source was not imported. Review the validation message above."
                }
                .buttonStyle(.borderedProminent)
                .disabled(onImportSource == nil || sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct AutomationBuilderInspectorShell<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(tint)
                }
            }
            Divider()
            content
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .font(.caption)
        .padding(13)
        .frame(minHeight: 566, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AutomationConditionDesignPanel: View {
    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Correction requested",
            subtitle: "Selected connection",
            symbol: "arrow.triangle.branch",
            tint: KanameColor.warning
        ) {
            Text("Follow this path when").font(.caption.weight(.semibold))
            conditionField("Interpret reply", symbol: "point.3.connected.trianglepath.dotted")
            conditionField("Intent", symbol: "chevron.right.2")
            HStack(spacing: 6) {
                conditionField("equals", symbol: "equal")
                conditionField("correction", symbol: "text.quote")
            }
            HStack {
                Button("+ AND") {}.buttonStyle(.bordered).controlSize(.small)
                Button("+ OR") {}.buttonStyle(.bordered).controlSize(.small)
            }
            Divider()
            Text("Sample evaluation").font(.caption.weight(.semibold))
            Label("Matched fixture: Customer correction #3", systemImage: "checkmark.circle.fill")
                .foregroundStyle(KanameColor.success)
            Text("“Please keep the totals but change the table layout.”")
                .foregroundStyle(.secondary)
            DisclosureGroup("Advanced predicate") {
                Text("/intent equals correction")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Label("1 of 3 outcomes tested", systemImage: "checkmark.seal")
                .foregroundStyle(KanameColor.warning)
        }
    }

    private func conditionField(_ text: String, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.caption.weight(.medium))
            Spacer()
            Image(systemName: "chevron.down").foregroundStyle(.secondary)
        }
        .padding(8)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct AutomationDataMappingDesignPanel: View {
    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Compile context",
            subtitle: "Input mapping",
            symbol: "text.append",
            tint: KanameColor.accent
        ) {
            Picker("Mapping", selection: .constant("Input")) {
                Text("Setup").tag("Setup")
                Text("Input").tag("Input")
                Text("Output").tag("Output")
                Text("Policy").tag("Policy")
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("Available data").font(.caption.weight(.semibold))
            dataSource("Inbound email", field: "thread.id", sample: "18f3…", tint: KanameColor.accent)
            dataSource("Interpret reply", field: "instruction", sample: "change layout", tint: KanameColor.warning)
            dataSource("Case state", field: "episodes[]", sample: "3 items", tint: KanameColor.blocked)
            Divider()
            Text("Node inputs").font(.caption.weight(.semibold))
            mappedField("caseID", source: "Inbound email · thread.id")
            mappedField("instructions", source: "Interpret reply · instruction")
            mappedField("history", source: "Case state · episodes[]")
        } footer: {
            Label("3 mappings · all types compatible", systemImage: "checkmark.seal.fill")
                .foregroundStyle(KanameColor.success)
        }
    }

    private func dataSource(_ title: String, field: String, sample: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Circle().fill(tint).frame(width: 6, height: 6); Text(title).fontWeight(.semibold); Spacer(); Image(systemName: "line.3.horizontal") }
            HStack { Text(field).font(.system(.caption2, design: .monospaced)); Spacer(); Text(sample).foregroundStyle(.secondary) }
        }
        .padding(8).background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
    }

    private func mappedField(_ target: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(target).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            HStack { Image(systemName: "link").foregroundStyle(KanameColor.accent); Text(source).lineLimit(1); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(KanameColor.success) }
        }
        .padding(8).background(KanameColor.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct AutomationStorageAccessDesignPanel: View {
    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Run work type",
            subtitle: "Storage access",
            symbol: "externaldrive.badge.checkmark",
            tint: KanameColor.accent
        ) {
            Text("Declared access").font(.caption.weight(.semibold))
            storageScope(
                "Job storage",
                detail: "Read + write",
                paths: "artifacts/draft/*\nstate/progress",
                symbol: "shippingbox.fill",
                tint: KanameColor.accent
            )
            storageScope(
                "Workflow storage",
                detail: "Read only",
                paths: "templates/*\nreference/*",
                symbol: "externaldrive.fill",
                tint: KanameColor.blocked
            )
            Divider()
            Text("Commit visibility").font(.caption.weight(.semibold))
            Label("Changes become visible after this node commits", systemImage: "checkmark.seal")
                .foregroundStyle(KanameColor.success)
            Text("Parallel branches may read the same job data. A same-key write conflict fails visibly unless an atomic update or Join is declared.")
                .foregroundStyle(.secondary)
            Divider()
            Label("No raw filesystem path", systemImage: "lock.shield.fill")
                .foregroundStyle(.secondary)
            Text("The node receives scoped file and value handles only.")
                .foregroundStyle(.secondary)
        } footer: {
            Label("2 scopes · no cross-workflow access", systemImage: "checkmark.seal.fill")
                .foregroundStyle(KanameColor.success)
        }
    }

    private func storageScope(
        _ title: String,
        detail: String,
        paths: String,
        symbol: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(detail).font(.caption2.weight(.bold)).foregroundStyle(tint)
            }
            Text(paths)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.28), lineWidth: 1) }
    }
}

private struct AutomationStoragePromotionDesignPanel: View {
    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Promote artifact",
            subtitle: "Durable storage write",
            symbol: "arrow.up.doc.fill",
            tint: KanameColor.warning
        ) {
            Text("Source · job storage").font(.caption.weight(.semibold))
            storagePath("outputs/report-v3.xlsx", detail: "48.0 MB · digest 7d91…a8c2", tint: KanameColor.accent)
            HStack {
                Spacer()
                Image(systemName: "arrow.down").foregroundStyle(KanameColor.warning)
                Spacer()
            }
            Text("Destination · workflow storage").font(.caption.weight(.semibold))
            storagePath("cases/CASE-184/current/report.xlsx", detail: "Durable across jobs and versions", tint: KanameColor.blocked)
            Divider()
            promotionFact("On conflict", value: "Create a new revision")
            promotionFact("Retention", value: "Until explicit removal")
            promotionFact("Provenance", value: "Job #184 + content digest")
            promotionFact("Publish impact", value: "Storage contract changed")
            Divider()
            Label("Copy, verify digest, then publish durable reference", systemImage: "checkmark.shield.fill")
                .foregroundStyle(KanameColor.success)
            Text("The original job copy remains available until the job is deleted.")
                .foregroundStyle(.secondary)
        } footer: {
            Label("Workflow copy survives job deletion", systemImage: "externaldrive.fill.badge.checkmark")
                .foregroundStyle(KanameColor.blocked)
        }
    }

    private func storagePath(_ path: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(path).font(.system(.caption2, design: .monospaced)).foregroundStyle(tint)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func promotionFact(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
    }
}

private struct AutomationNodeTestDesignPanel: View {
    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Interpret reply",
            subtitle: "Test node",
            symbol: "play.square.stack",
            tint: KanameColor.success
        ) {
            Text("Fixture").font(.caption.weight(.semibold))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Customer correction #3").fontWeight(.semibold)
                    Text("Redacted historical input").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "chevron.down")
            }
            .padding(9).background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Test node", systemImage: "play.fill") {}.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Test path") {}.buttonStyle(.bordered).controlSize(.small)
            }
            Divider()
            Label("Completed in 1.2 s", systemImage: "checkmark.circle.fill").foregroundStyle(KanameColor.success)
            testFact("Outcome", value: "correction")
            testFact("Confidence", value: "0.96")
            testFact("Next path", value: "Append episode")
            Divider()
            Text("Output preview").font(.caption.weight(.semibold))
            Text("{\n  intent: correction,\n  preserveTotals: true,\n  requestedChange: tableLayout\n}")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(KanameColor.accent)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
        } footer: {
            Label("Effect nodes remain proposed only", systemImage: "network.slash")
                .foregroundStyle(.secondary)
        }
    }

    private func testFact(_ label: String, value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.semibold) }
    }
}

private struct AutomationPublishReviewDesignPanel: View {
    let currentVersion: Int

    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Review v\(currentVersion + 1)",
            subtitle: "Publish checkpoint",
            symbol: "arrow.up.doc.fill",
            tint: KanameColor.success
        ) {
            HStack {
                Text("v\(currentVersion)").foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                Text("v\(currentVersion + 1)").fontWeight(.bold)
                Spacer(); Text("Draft").foregroundStyle(KanameColor.warning)
            }
            reviewRow("Graph", detail: "+2 nodes · +3 connections", state: .attention)
            reviewRow("Mappings", detail: "3 changed · all valid", state: .passed)
            reviewRow("Subflows", detail: "Work subflow pinned v3", state: .passed)
            reviewRow("Fixtures", detail: "6 of 6 paths pass", state: .passed)
            reviewRow("Authority", detail: "No increase", state: .passed)
            Divider()
            Text("Activation").font(.caption.weight(.semibold))
            Label("Publish without activating", systemImage: "circle.inset.filled")
                .foregroundStyle(KanameColor.accent)
            Text("Existing runs remain on their original definition. Activation is a separate action.")
                .foregroundStyle(.secondary)
            Button("View visual diff", systemImage: "point.3.connected.trianglepath.dotted") {}
                .buttonStyle(.bordered).controlSize(.small)
        } footer: {
            Button("Publish immutable v\(currentVersion + 1)", systemImage: "checkmark.seal.fill") {}
                .buttonStyle(.borderedProminent)
        }
    }

    private enum ReviewState { case passed, attention }

    private func reviewRow(_ title: String, detail: String, state: ReviewState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state == .passed ? "checkmark.circle.fill" : "circlebadge.2.fill")
                .foregroundStyle(state == .passed ? KanameColor.success : KanameColor.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private enum AutomationWorkflowDiagnosticFixture {
    static let presentations: [DesktopWorkflowDiagnosticPresentation] = {
        var response = Kaname_V1_CompileWorkflowResponse()
        response.diagnostics = [
            diagnostic(
                code: "graph.entrypoint.missing",
                severity: .error,
                summary: "Choose one entry node before publishing.",
                pointer: "/graph/entryNodeID",
                line: 3,
                byteOffset: 48
            ),
            diagnostic(
                code: "graph.node.unreachable",
                severity: .warning,
                summary: "Append episode has no reachable incoming route.",
                pointer: "/graph/nodes/7",
                line: 7,
                byteOffset: 212
            ),
            diagnostic(
                code: "mapping.type.incompatible",
                severity: .error,
                summary: "The correction value does not match the declared input type.",
                pointer: "/graph/nodes/2/configuration/mappings/0",
                line: 6,
                byteOffset: 176
            ),
            diagnostic(
                code: "graph.cycle.unbounded",
                severity: .error,
                summary: "The feedback cycle requires an iteration or time bound.",
                pointer: "/graph/edges/9",
                line: 9,
                byteOffset: 284
            ),
            diagnostic(
                code: "effect.authority.undeclared",
                severity: .error,
                summary: "Reply + attach requires an explicit send authority envelope.",
                pointer: "/graph/nodes/5/authority",
                line: 8,
                byteOffset: 252
            ),
        ]
        let routes: [DesktopWorkflowDiagnosticRouteKey: DesktopWorkflowDiagnosticFocusTarget] = [
            .init(code: "graph.node.unreachable", instancePointer: "/graph/nodes/7"):
                .outline(nodeID: "append"),
            .init(code: "graph.cycle.unbounded", instancePointer: "/graph/edges/9"):
                .canvas(nodeID: "interpret", edgeID: "append-context-episode 4 · same case"),
            .init(code: "effect.authority.undeclared", instancePointer: "/graph/nodes/5/authority"):
                .canvas(nodeID: "reply"),
        ]
        let fixes: [DesktopWorkflowDiagnosticRouteKey: DesktopWorkflowDiagnosticFixMetadata] = [
            .init(code: "graph.entrypoint.missing", instancePointer: "/graph/entryNodeID"):
                .init(
                    id: "choose-entry-node",
                    title: "Preview entry selection",
                    explanation: "Shows the eligible trigger nodes without changing the draft."
                ),
        ]
        return DesktopWorkflowDiagnosticMapper.presentations(
            response: response,
            routes: routes,
            fixes: fixes
        )
    }()

    private static func diagnostic(
        code: String,
        severity: Kaname_V1_WorkflowDiagnosticSeverity,
        summary: String,
        pointer: String,
        line: UInt32,
        byteOffset: UInt64
    ) -> Kaname_V1_WorkflowDiagnostic {
        var start = Kaname_V1_WorkflowSourcePosition()
        start.byteOffset = byteOffset
        start.line = line
        start.column = 4
        var end = start
        end.byteOffset += 18
        end.column += 18
        var location = Kaname_V1_WorkflowSourceLocation()
        location.sourceID = "workflow.json"
        location.jsonPointer = pointer
        location.start = start
        location.end = end
        var result = Kaname_V1_WorkflowDiagnostic()
        result.code = code
        result.severity = severity
        result.summary = summary
        result.instancePointer = pointer
        result.schemaPointer = "/properties/graph"
        result.location = location
        return result
    }
}

private struct AutomationProblemsDrawer: View {
    let diagnostics: [DesktopWorkflowDiagnosticPresentation]
    @Binding var selectedID: String?
    @Binding var isExpanded: Bool
    let focusMessage: String?
    let onFocus: (DesktopWorkflowDiagnosticPresentation) -> Void
    @State private var previewedFixID: String?

    private var selected: DesktopWorkflowDiagnosticPresentation? {
        diagnostics.first { $0.id == selectedID } ?? diagnostics.first
    }

    var body: some View {
        Group {
            if isExpanded {
                expandedDrawer
            } else {
                collapsedDrawer
            }
        }
        .padding(isExpanded ? 13 : 8)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var collapsedDrawer: some View {
        Button {
            isExpanded = true
        } label: {
            HStack(spacing: 8) {
                Label("Problems", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text("\(diagnostics.count)")
                    .foregroundStyle(KanameColor.warning)
                severitySummary
                Spacer()
                Text("Show diagnostics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Problems, \(diagnostics.count) diagnostics")
    }

    private var expandedDrawer: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Problems", systemImage: "exclamationmark.triangle.fill").font(.headline)
                    Text("\(diagnostics.count)").foregroundStyle(KanameColor.warning)
                    Spacer()
                    Text("Select an item to focus its exact graph or source location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        isExpanded = false
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collapse Problems")
                }
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(diagnostics) { diagnostic in
                            Button {
                                selectedID = diagnostic.id
                                onFocus(diagnostic)
                            } label: {
                                problem(diagnostic)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(diagnostic.accessibilityLabel)
                            .accessibilityHint("Focuses the declared \(diagnostic.focusTarget.projection.rawValue) location")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Selected problem").font(.caption.weight(.semibold))
                if let selected {
                    Text(selected.code).font(.system(.caption, design: .monospaced).weight(.bold))
                    Text(selected.summary).font(.headline)
                    Text(selected.instancePointer)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(KanameColor.accent)
                    HStack {
                        Button("Focus \(selected.focusTarget.projection.rawValue.capitalized)") {
                            onFocus(selected)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        if let fix = selected.fix {
                            Button(fix.title) { previewedFixID = fix.id }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    if previewedFixID == selected.fix?.id, let fix = selected.fix {
                        Label(fix.explanation, systemImage: "eye")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let focusMessage {
                        Text(focusMessage).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 390, alignment: .leading)
        }
    }

    private var severitySummary: some View {
        let errors = diagnostics.filter { $0.severity == .error }.count
        let warnings = diagnostics.filter { $0.severity == .warning }.count
        return HStack(spacing: 8) {
            Label("\(errors) errors", systemImage: "xmark.octagon.fill")
                .foregroundStyle(KanameColor.danger)
            Label("\(warnings) warnings", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(KanameColor.warning)
        }
        .font(.caption2)
    }

    private func problem(_ diagnostic: DesktopWorkflowDiagnosticPresentation) -> some View {
        let selected = selectedID == diagnostic.id
        return HStack(spacing: 8) {
            Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(diagnostic.severity == .error ? KanameColor.danger : KanameColor.warning)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(diagnostic.code).font(.system(.caption2, design: .monospaced).weight(.bold))
                Text(diagnostic.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(diagnostic.focusTarget.projection.rawValue.capitalized)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(KanameColor.accent)
            Image(systemName: selected ? "scope" : "chevron.right")
                .foregroundStyle(selected ? KanameColor.accent : .secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(selected ? KanameColor.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct AutomationVersionHistoryPanel: View {
    let currentVersion: Int

    private var versions: [(Int, String, String, Bool)] {
        (0..<min(currentVersion, 4)).map { offset in
            let version = currentVersion - offset
            if offset == 0 { return (version, "Current", "Published today · 3 runs", true) }
            if offset == 3 { return (version, "Retired", "18 Jul · 8 runs", false) }
            return (version, "Published", offset == 1 ? "9 Aug · 12 runs" : "2 Aug · 21 runs", false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Versions").font(.headline)
                Spacer()
                Text("4 retained").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Each publish creates an immutable revision. Runs keep the exact graph and settings they used.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(versions, id: \.0) { version in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("v\(version.0)").font(.system(.caption, design: .monospaced).weight(.bold))
                        Text(version.1)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(version.3 ? KanameColor.success : .secondary)
                        Spacer()
                        if version.3 { Image(systemName: "checkmark.circle.fill").foregroundStyle(KanameColor.success) }
                    }
                    Text(version.2).font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .font(.system(size: 9)).foregroundStyle(KanameColor.accent)
                }
                .padding(9)
                .background(version.3 ? KanameColor.accent.opacity(0.12) : KanameColor.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            }
            Spacer(minLength: 0)
            Divider()
            Button(
                "Compare v\(max(1, currentVersion - 1)) ↔ v\(currentVersion)",
                systemImage: "arrow.left.arrow.right"
            ) {}
                .buttonStyle(.bordered)
                .disabled(true)
            Label("Published versions cannot be edited", systemImage: "lock.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(13)
        .frame(minHeight: 566, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AutomationLiveVersionHistoryPanel: View {
    let revisions: [DesktopWorkflowRevisionRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Versions").font(.headline)
                Spacer()
                Text("\(revisions.count) retained").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Each publish creates an immutable revision. Runs keep the exact graph and settings they used.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if revisions.isEmpty {
                Text("No published revisions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(revisions.enumerated()), id: \.element.id) { index, revision in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("v\(revision.version)")
                                .font(.system(.caption, design: .monospaced).weight(.bold))
                            Text(index == 0 ? "Current" : "Published")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(index == 0 ? KanameColor.success : .secondary)
                            Spacer()
                            if index == 0 {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(KanameColor.success)
                            }
                        }
                        Text(installedLabel(revision.installedAtUnixMillis))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(String(revision.manifestDigest.prefix(12)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(KanameColor.accent)
                    }
                    .padding(9)
                    .background(
                        index == 0 ? KanameColor.accent.opacity(0.12) : KanameColor.raised.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
            }
            Spacer(minLength: 0)
            Divider()
            Label("Published versions cannot be edited", systemImage: "lock.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(13)
        .frame(minHeight: 566, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func installedLabel(_ unixMillis: Int64) -> String {
        Date(timeIntervalSince1970: Double(unixMillis) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct AutomationNodeInspector: View {
    let step: AutomationCanvasStep
    @Binding var section: AutomationInspectorSection
    let showsCaseHistory: Bool
    var isLive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: step.symbol)
                    .foregroundStyle(step.kind.tint)
                    .frame(width: 28, height: 28)
                    .background(step.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.headline).lineLimit(1)
                    Text(step.kind.label).font(.caption2.weight(.bold)).foregroundStyle(step.kind.tint)
                }
            }

            Picker("Inspector", selection: $section) {
                ForEach(AutomationInspectorSection.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            inspectorContent
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 7) {
                Image(systemName: isLive ? "shippingbox" : "testtube.2")
                Text(isLive
                    ? "Installed contract · qualification shown in Readiness"
                    : "Synthetic fixture contract · not operational")
            }
            .foregroundStyle(isLive ? KanameColor.accent : KanameColor.warning)
            Label(isLive ? "Bindings and authority are managed in Readiness" : "No live connections", systemImage: "network.slash")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(13)
        .frame(minHeight: 566, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch section {
        case .configuration:
            inspectorFact("Node ID", value: step.id)
            inspectorFact("Execution", value: executionLabel)
            if step.state == .executable || step.state == .schemaOnly {
                inspectorFact("Compiler", value: step.state.label)
            }
            inspectorFact("Retry", value: retryLabel)
            Divider()
            if let reason = step.availabilityReason {
                Label(reason, systemImage: "bolt.slash.circle")
                    .foregroundStyle(KanameColor.warning)
                Divider()
            }
            Text(step.subtitle).foregroundStyle(.secondary)
        case .data:
            inspectorFact("Input", value: step.input)
            inspectorFact("Output", value: step.output)
            inspectorFact("Retention", value: "Until settled")
            Divider()
            Label("Typed ports validated", systemImage: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(KanameColor.accent)
        case .history:
            if showsCaseHistory {
                inspectorFact("Case", value: "CASE-184 · open")
                inspectorFact("Conversation", value: "One durable context")
                inspectorFact("Current", value: "Episode 3 · correction")
                inspectorFact("Artifacts", value: "v3 current · v1–v2 retained")
                Divider()
                historyRow("1", title: "Initial request", detail: "Artifact v1 · superseded", state: .complete)
                historyRow("2", title: "Correction", detail: "Artifact v2 · superseded", state: .complete)
                historyRow("3", title: "Revised attachment", detail: "Artifact v3 · current", state: .running)
                Divider()
                Text("Only current facts and required evidence enter the next model context. The complete lineage stays inspectable.")
                    .foregroundStyle(.secondary)
            } else {
                inspectorFact("Run", value: "#184")
                inspectorFact("Definition", value: "revision 1.0.0")
                inspectorFact("Input snapshot", value: "Immutable")
                inspectorFact("Replay boundary", value: retryLabel)
                Divider()
                Text("Published definitions and completed node attempts remain immutable.")
                    .foregroundStyle(.secondary)
            }
        case .safety:
            inspectorFact("Authority", value: step.authority)
            inspectorFact("Network", value: step.kind == .effect ? "Allowlisted connector" : "None by default")
            inspectorFact("Model egress", value: step.kind == .ai ? "Declared projection" : "None")
            Divider()
            Text(step.kind == .effect ? "The exact target and approval are rechecked immediately before execution." : "This node cannot inherit effect authority from its trigger or upstream nodes.")
                .foregroundStyle(step.kind == .effect ? KanameColor.warning : .secondary)
        }
    }

    private var executionLabel: String {
        switch step.kind {
        case .human, .wait: "Durable pause"
        case .decision, .policy, .data, .loop, .join, .parallel: "Deterministic"
        case .ai: "Model-assisted"
        case .context: "Deterministic projection"
        case .effect: "Privileged connector"
        case .trigger: "Event observation"
        case .error: "Blocked attention"
        case .subflow: "Pinned revision"
        case .receipt: "Local evidence"
        }
    }

    private var retryLabel: String {
        switch step.kind {
        case .effect: "Only known-safe failures"
        case .error: "Never automatic"
        case .human, .wait: "Resume, not retry"
        default: "From captured input"
        }
    }

    private func inspectorFact(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).textSelection(.enabled)
        }
    }

    private func historyRow(
        _ episode: String,
        title: String,
        detail: String,
        state: AutomationPreviewState
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(episode)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(state.tint)
                .frame(width: 18, height: 18)
                .background(state.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private enum AutomationRunRetention: String, CaseIterable {
    case thirtyDays = "30 days"
    case deleteAfterSuccess = "Delete after success"
    case forever = "Keep forever"
}

private struct AutomationRunFixture: Identifiable {
    let id: Int
    let workflow: String
    let version: Int
    let detail: String
    let state: AutomationPreviewState
    let pattern: AutomationCanvasPattern
    let expiry: String
}

private enum AutomationRunInspectorTab: String, CaseIterable {
    case data = "Data"
    case storage = "Storage"
    case logs = "Logs"
    case configuration = "Config"
    case evidence = "Evidence"
}

private enum AutomationRunDataView: String, CaseIterable {
    case table = "Table"
    case json = "JSON"
    case schema = "Schema"
}

private enum AutomationStepInspectorSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case inputs = "Inputs"
    case context = "Context"
    case messages = "Messages"
    case tools = "Tools"
    case outputs = "Output"
    case errors = "Errors"
    case usage = "Usage"
    case storage = "Storage"
    case logs = "Logs"
    case raw = "Raw evidence"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .inputs: "arrow.down.doc"
        case .context: "text.append"
        case .messages: "bubble.left.and.bubble.right"
        case .tools: "wrench.and.screwdriver"
        case .outputs: "arrow.up.doc"
        case .errors: "exclamationmark.triangle"
        case .usage: "gauge.with.dots.needle.67percent"
        case .storage: "shippingbox"
        case .logs: "text.alignleft"
        case .raw: "chevron.left.forwardslash.chevron.right"
        }
    }
}

private enum AutomationRunStepInspectorPreview {
    case automatic
    case inputs
    case error
    case llmContext
    case llmMessages
    case llmTools

    init(arguments: [String]) {
        if arguments.contains("--desktop-automation-run-step-detail") { self = .inputs }
        else if arguments.contains("--desktop-automation-run-step-error") { self = .error }
        else if arguments.contains("--desktop-automation-run-llm-context") { self = .llmContext }
        else if arguments.contains("--desktop-automation-run-llm-messages") { self = .llmMessages }
        else if arguments.contains("--desktop-automation-run-llm-tools") { self = .llmTools }
        else { self = .automatic }
    }
}

private struct AutomationRunsPreview: View {
    private let showsJobStorageDesign: Bool
    @State private var selectedRunID = 184
    @State private var retention = AutomationRunRetention.thirtyDays
    @State private var search = ""
    @State private var showsRetentionSettings = false
    @State private var compactShowsDetail = false
    @State private var selectedRunStepID = "context"
    @State private var selectedRunEdgeID: String?
    @State private var inspectorTab = AutomationRunInspectorTab.data
    @State private var dataView = AutomationRunDataView.table
    @State private var stepInspectorSection = AutomationStepInspectorSection.inputs
    @State private var showsDeleteJobConfirmation = false

    private let runs: [AutomationRunFixture] = [
        .init(id: 184, workflow: "Reply-driven reporting", version: 6, detail: "Waiting for reply · 12 min", state: .waiting, pattern: .feedback, expiry: "Deletes 12 Sep"),
        .init(id: 183, workflow: "Reply-driven reporting", version: 6, detail: "Passed · 1 h ago", state: .complete, pattern: .feedback, expiry: "Deletes 12 Sep"),
        .init(id: 182, workflow: "Reply-driven reporting", version: 5, detail: "Passed · yesterday", state: .complete, pattern: .feedback, expiry: "Deletes 11 Sep"),
        .init(id: 181, workflow: "Mailbox review", version: 4, detail: "Failed · yesterday", state: .blocked, pattern: .decision, expiry: "Deletes 11 Sep"),
        .init(id: 180, workflow: "Approved cleanup", version: 3, detail: "Passed · 3 d ago", state: .complete, pattern: .approval, expiry: "Deletes 9 Sep"),
        .init(id: 179, workflow: "Mailbox digest", version: 3, detail: "Passed · 4 d ago", state: .complete, pattern: .parallel, expiry: "Deletes 8 Sep"),
        .init(id: 178, workflow: "Approved cleanup", version: 3, detail: "Failed · 5 d ago", state: .blocked, pattern: .recovery, expiry: "Deletes 7 Sep"),
    ]

    init() {
        let arguments = CommandLine.arguments
        let requestedStepInspector = AutomationRunStepInspectorPreview(arguments: arguments)
        let startsWithDeletePreview = arguments.contains("--desktop-automation-run-storage-delete")
        showsJobStorageDesign = arguments.contains("--desktop-automation-run-storage") || startsWithDeletePreview
        if arguments.contains("--desktop-automation-run-edge") {
            _selectedRunEdgeID = State(initialValue: "context-execute-episode 3")
        }
        if showsJobStorageDesign {
            _inspectorTab = State(initialValue: .storage)
        }
        if startsWithDeletePreview {
            _selectedRunID = State(initialValue: 183)
            _showsDeleteJobConfirmation = State(initialValue: true)
        }
        switch requestedStepInspector {
        case .inputs:
            _selectedRunID = State(initialValue: 184)
            _selectedRunStepID = State(initialValue: "context")
            _stepInspectorSection = State(initialValue: .inputs)
        case .error:
            _selectedRunID = State(initialValue: 178)
            _selectedRunStepID = State(initialValue: "unknown")
            _stepInspectorSection = State(initialValue: .errors)
        case .llmContext:
            _selectedRunID = State(initialValue: 179)
            _selectedRunStepID = State(initialValue: "summarize")
            _stepInspectorSection = State(initialValue: .context)
        case .llmMessages:
            _selectedRunID = State(initialValue: 179)
            _selectedRunStepID = State(initialValue: "summarize")
            _stepInspectorSection = State(initialValue: .messages)
        case .llmTools:
            _selectedRunID = State(initialValue: 179)
            _selectedRunStepID = State(initialValue: "summarize")
            _stepInspectorSection = State(initialValue: .tools)
        case .automatic:
            break
        }
    }

    private var selectedRun: AutomationRunFixture {
        runs.first(where: { $0.id == selectedRunID }) ?? runs[0]
    }

    private var visibleRuns: [AutomationRunFixture] {
        runs.filter { search.isEmpty || $0.workflow.localizedCaseInsensitiveContains(search) || String($0.id).contains(search) }
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 1_050
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(showsRetentionSettings ? "History settings" : "Run history")
                            .font(.title3.weight(.bold))
                        Text(showsRetentionSettings
                            ? "Choose how long settled run data remains available"
                            : "Every run is pinned to the exact workflow version and evidence it used")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !showsRetentionSettings {
                        TextField("Search runs", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: isCompact ? 180 : 220)
                    }
                    Button(
                        showsRetentionSettings ? "Back to runs" : "History settings",
                        systemImage: showsRetentionSettings ? "chevron.left" : "gearshape"
                    ) {
                        showsRetentionSettings.toggle()
                    }
                    .buttonStyle(.bordered)
                }

                if showsRetentionSettings {
                    retentionSettings
                } else if isCompact {
                    if compactShowsDetail {
                        runDetail(isCompact: true)
                    } else {
                        runList
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        runList
                            .frame(width: 290)
                        runDetail(isCompact: false)
                    }
                }
            }
        }
        .frame(minHeight: 630)
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent runs").font(.headline)
                Spacer()
                Text("\(visibleRuns.count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            ForEach(visibleRuns) { run in
                Button {
                    selectedRunID = run.id
                    selectedRunStepID = run.pattern.graph.defaultSelectedID
                    selectedRunEdgeID = nil
                    let defaultStep = run.pattern.graph.steps.first(where: { $0.id == run.pattern.graph.defaultSelectedID })
                        ?? run.pattern.graph.steps[0]
                    stepInspectorSection = defaultStepInspectorSection(for: defaultStep, run: run)
                    compactShowsDetail = true
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: run.state.symbol).foregroundStyle(run.state.tint).frame(width: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text("#\(run.id)").font(.system(.caption, design: .monospaced).weight(.bold))
                                Text("v\(run.version)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(KanameColor.accent)
                            }
                            Text(run.workflow).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(run.detail).font(.caption2).foregroundStyle(.secondary)
                            Text(run.expiry).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Open run details")
                    }
                    .padding(9)
                    .background(selectedRunID == run.id ? KanameColor.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Divider()
            Label("History is local and manually deletable", systemImage: "internaldrive")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(13)
        .frame(minHeight: 590, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func runDetail(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if isCompact {
                    Button("All runs", systemImage: "chevron.left") {
                        compactShowsDetail = false
                    }
                    .buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selectedRun.workflow) #\(selectedRun.id)").font(.headline)
                    HStack(spacing: 8) {
                        Label(selectedRun.state.label, systemImage: selectedRun.state.symbol).foregroundStyle(selectedRun.state.tint)
                        Text("Workflow v\(selectedRun.version)")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(KanameColor.accent)
                        Label("Historical snapshot", systemImage: "lock.doc")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                Spacer()
                Button("Delete job", systemImage: "trash", role: .destructive) {
                    showsDeleteJobConfirmation = true
                }
                    .buttonStyle(.bordered)
                    .disabled(!showsJobStorageDesign)
            }

            HStack {
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted").foregroundStyle(KanameColor.accent)
                Label("Settings v\(selectedRun.version)", systemImage: "slider.horizontal.3").foregroundStyle(.secondary)
                Label("Evidence", systemImage: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                Spacer()
                Text("Read-only").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .font(.caption)

            AutomationNodeCanvas(
                graph: selectedRun.pattern.graph,
                selectedStepID: $selectedRunStepID,
                isSimulating: selectedRun.state == .running || selectedRun.state == .waiting,
                viewportPreset: showsJobStorageDesign || usesDetailedStepInspector ? .readable : .standard,
                selectedEdgeID: $selectedRunEdgeID
            )
            .frame(minHeight: 315)
            .onChange(of: selectedRunStepID) { _ in
                selectedRunEdgeID = nil
                stepInspectorSection = defaultStepInspectorSection(for: selectedRunStep, run: selectedRun)
            }

            runDataInspector
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 590, alignment: .topLeading)
        .background(KanameColor.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if showsDeleteJobConfirmation {
                ZStack {
                    KanameColor.canvas.opacity(0.74)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    deleteJobConfirmation
                        .frame(width: 450)
                }
            }
        }
    }

    private var selectedRunStep: AutomationCanvasStep {
        selectedRun.pattern.graph.steps.first(where: { $0.id == selectedRunStepID })
            ?? selectedRun.pattern.graph.steps[0]
    }

    private var selectedRunEdge: AutomationCanvasEdge? {
        selectedRun.pattern.graph.edges.first(where: { $0.id == selectedRunEdgeID })
    }

    private var usesDetailedStepInspector: Bool {
        !showsJobStorageDesign && selectedRunEdge == nil
    }

    @ViewBuilder
    private var runDataInspector: some View {
        if usesDetailedStepInspector {
            detailedStepInspector
        } else {
            legacyRunDataInspector
        }
    }

    private var legacyRunDataInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: selectedRunEdge == nil ? selectedRunStep.symbol : "arrow.right.circle.fill")
                    .foregroundStyle(selectedRunEdge?.kind.tint ?? selectedRunStep.kind.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedRunEdge.map { "Checkpoint · \($0.label)" } ?? selectedRunStep.title)
                        .font(.headline)
                    Text(selectedRunEdge.map { edgeEndpointLabel($0) } ?? "Node attempt · received → produced")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Inspector", selection: $inspectorTab) {
                    ForEach(AutomationRunInspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }

            Divider()
            runInspectorContent
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var detailedStepInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: selectedRunStep.symbol)
                    .foregroundStyle(selectedRunStep.kind.tint)
                    .frame(width: 30, height: 30)
                    .background(selectedRunStep.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(selectedRunStep.title).font(.headline)
                        Text("Attempt 1")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(stepInspectorSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                inspectorStatusFact("Status", value: selectedRun.state == .blocked ? "Failed" : "Succeeded", tint: selectedRun.state.tint)
                inspectorStatusFact("Duration", value: stepIsLLM ? "1.8 s" : "16 ms", tint: KanameColor.accent)
                inspectorStatusFact("Started", value: "22:31:04", tint: .secondary)
                Label("Read-only trace", systemImage: "lock.doc")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 3) {
                    ForEach(stepInspectorSections) { section in
                        stepInspectorNavigationItem(section)
                    }
                }
                .frame(width: 146)

                Divider()

                detailedStepInspectorContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 286, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var stepInspectorSubtitle: String {
        if stepIsLLM {
            return "LLM execution · context, messages, tools, output, and provider metadata"
        }
        if selectedRun.state == .blocked {
            return "Failed node attempt · preserved input checkpoint and diagnostic evidence"
        }
        return "Node execution · exact input boundary → produced output boundary"
    }

    private var stepIsLLM: Bool {
        if case .ai = selectedRunStep.kind { return true }
        return false
    }

    private var stepInspectorSections: [AutomationStepInspectorSection] {
        if stepIsLLM {
            return [.overview, .inputs, .context, .messages, .tools, .outputs, .errors, .usage, .raw]
        }
        return [.overview, .inputs, .outputs, .errors, .storage, .logs, .raw]
    }

    private func defaultStepInspectorSection(
        for step: AutomationCanvasStep,
        run: AutomationRunFixture
    ) -> AutomationStepInspectorSection {
        if case .ai = step.kind { return .context }
        if run.state == .blocked { return .errors }
        return .inputs
    }

    private func stepInspectorNavigationItem(_ section: AutomationStepInspectorSection) -> some View {
        Button {
            stepInspectorSection = section
        } label: {
            HStack(spacing: 7) {
                Image(systemName: section.symbol).frame(width: 15)
                Text(section.rawValue).lineLimit(1)
                Spacer(minLength: 4)
                if let count = stepInspectorCount(for: section) {
                    Text(count)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(section == .errors && count != "0" ? KanameColor.danger : .secondary)
                }
            }
            .font(.caption.weight(stepInspectorSection == section ? .semibold : .regular))
            .foregroundStyle(stepInspectorSection == section ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                stepInspectorSection == section ? selectedRunStep.kind.tint.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stepInspectorCount(for section: AutomationStepInspectorSection) -> String? {
        switch section {
        case .inputs: stepIsLLM ? "4" : "3"
        case .context: "5"
        case .messages: "4"
        case .tools: "2"
        case .outputs: stepIsLLM ? "2" : "4"
        case .errors: selectedRun.state == .blocked ? "1" : "0"
        case .storage: "2"
        default: nil
        }
    }

    @ViewBuilder
    private var detailedStepInspectorContent: some View {
        switch stepInspectorSection {
        case .overview:
            stepOverviewContent
        case .inputs:
            stepInputsAndOutputsContent
        case .context:
            llmContextContent
        case .messages:
            llmMessagesContent
        case .tools:
            llmToolsAndUsageContent
        case .outputs:
            stepOutputContent
        case .errors:
            stepErrorsContent
        case .usage:
            llmUsageContent
        case .storage:
            jobStorageInspector
        case .logs:
            VStack(alignment: .leading, spacing: 8) {
                sectionHeading("Structured logs", detail: "Four events · node-local timestamps")
                runLogLine("22:31:04.218", "Loaded immutable input checkpoint", KanameColor.separator)
                runLogLine("22:31:04.231", "Validated input schema case-context.v3", KanameColor.success)
                runLogLine("22:31:04.247", "Committed output checkpoint 7d91…a8c2", KanameColor.accent)
                runLogLine("22:31:04.251", "Released job-storage write lease", KanameColor.blocked)
            }
        case .raw:
            rawStepEvidenceContent
        }
    }

    private var stepOverviewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("What happened", detail: "A concise summary before opening the underlying records")
            HStack(spacing: 10) {
                overviewTile("Input", value: "3 variables · 2.4 KB", symbol: "arrow.down.doc", tint: KanameColor.accent)
                overviewTile("Output", value: selectedRun.state == .blocked ? "No output committed" : "4 values · 6.8 KB", symbol: "arrow.up.doc", tint: selectedRun.state == .blocked ? KanameColor.danger : KanameColor.success)
                overviewTile("Storage", value: "2 job values changed", symbol: "shippingbox", tint: KanameColor.blocked)
                overviewTile("Evidence", value: "Input + output digests", symbol: "checkmark.seal", tint: KanameColor.warning)
            }
            Label(
                selectedRun.state == .blocked
                    ? "The failed attempt preserved its input checkpoint. No partial output became visible downstream."
                    : "Downstream nodes received only the committed output checkpoint shown here.",
                systemImage: selectedRun.state == .blocked ? "exclamationmark.shield" : "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(selectedRun.state == .blocked ? KanameColor.danger : KanameColor.success)
        }
    }

    private var stepInputsAndOutputsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Variables at this node", detail: "Value, type, and provenance are kept together")
            HStack(alignment: .top, spacing: 10) {
                executionDataPanel(
                    "Variables passed in",
                    subtitle: "Immutable input checkpoint · b840…19fc",
                    tint: KanameColor.accent,
                    rows: [
                        ("case_id", "String", "CASE-184", "Correlate case"),
                        ("episode", "Integer", "3", "Job storage"),
                        ("current_reply", "String", "Change the totals…", "Inbound email"),
                    ]
                )
                executionDataPanel(
                    "Output produced",
                    subtitle: selectedRun.state == .blocked ? "No checkpoint committed" : "Committed checkpoint · 7d91…a8c2",
                    tint: selectedRun.state == .blocked ? KanameColor.danger : KanameColor.success,
                    rows: selectedRun.state == .blocked ? [
                        ("—", "—", "No output", "Attempt failed"),
                    ] : [
                        ("context_pack", "Object", "5 grouped sections", "This node"),
                        ("message_count", "Integer", "4", "This node"),
                        ("artifact_ref", "File", "report-v2.xlsx", "Job storage"),
                    ]
                )
            }
        }
    }

    private var stepOutputContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Committed output", detail: "Only this checkpoint became visible to downstream nodes")
            executionDataPanel(
                stepIsLLM ? "Assistant result" : "Produced values",
                subtitle: selectedRun.state == .blocked ? "No checkpoint committed" : "Schema-valid · digest 7d91…a8c2",
                tint: selectedRun.state == .blocked ? KanameColor.danger : KanameColor.success,
                rows: selectedRun.state == .blocked ? [
                    ("—", "—", "No output", "Attempt failed"),
                ] : stepIsLLM ? [
                    ("summary", "String", "12 mailbox themes…", "Model response"),
                    ("citations", "Array", "2 source references", "Validated output"),
                ] : [
                    ("context_pack", "Object", "5 grouped sections", "This node"),
                    ("message_count", "Integer", "4", "This node"),
                    ("artifact_ref", "File", "report-v2.xlsx", "Job storage"),
                    ("redactions", "Integer", "2", "Privacy policy"),
                ]
            )
        }
    }

    @ViewBuilder
    private var stepErrorsContent: some View {
        if selectedRun.state == .blocked {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(KanameColor.danger)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Provider outcome could not be proven").font(.caption.weight(.bold))
                        Text("The effect may have completed, so Kaname will not retry it automatically.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("UNKNOWN_OUTCOME")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(KanameColor.danger)
                }
                .padding(9)
                .background(KanameColor.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))

                HStack(alignment: .top, spacing: 10) {
                    diagnosticPanel(
                        "What failed",
                        rows: [
                            ("Stage", "Post-effect reconciliation"),
                            ("Safe message", "Provider response timed out"),
                            ("Technical cause", "Transport closed before receipt"),
                            ("Error ID", "err_01J8…M4Q"),
                        ],
                        tint: KanameColor.danger
                    )
                    diagnosticPanel(
                        "What happens next",
                        rows: [
                            ("Retry", "Blocked — outcome is ambiguous"),
                            ("Input", "Checkpoint retained"),
                            ("Output", "Nothing committed downstream"),
                            ("Recovery", "Human reconcile with provider"),
                        ],
                        tint: KanameColor.warning
                    )
                }
                HStack {
                    Label("Stack trace and provider payload are available under Technical detail", systemImage: "chevron.right")
                    Spacer()
                    Button("Open technical detail") {}
                        .buttonStyle(.borderless)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("Errors", detail: "No warnings or failures were recorded for this attempt")
                Label("Succeeded without retries", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KanameColor.success)
            }
        }
    }

    private var llmContextContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Context envelope sent to the model", detail: "Five named groups · 6,240 tokens · two protected fields redacted")
            HStack(alignment: .top, spacing: 8) {
                contextEnvelopeCard(
                    "System policy",
                    detail: "Mailbox summarizer · no external effects",
                    provenance: "Kaname policy · 620 tokens",
                    symbol: "shield.fill",
                    tint: KanameColor.warning
                )
                contextEnvelopeCard(
                    "Workflow instructions",
                    detail: "Summarize only the declared projection",
                    provenance: "Workflow v3 · 580 tokens",
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: KanameColor.blocked
                )
                contextEnvelopeCard(
                    "Current input",
                    detail: "184 messages · allowed fields only",
                    provenance: "Fan out · 3,820 tokens",
                    symbol: "arrow.down.doc",
                    tint: KanameColor.accent
                )
            }
            HStack(alignment: .top, spacing: 8) {
                contextEnvelopeCard(
                    "Conversation history",
                    detail: "3 prior messages · role-separated",
                    provenance: "Case thread · 1,140 tokens",
                    symbol: "bubble.left.and.bubble.right",
                    tint: KanameColor.active
                )
                contextEnvelopeCard(
                    "Attachments & sources",
                    detail: "2 retrieved excerpts · content digests retained",
                    provenance: "Job storage · 80 tokens",
                    symbol: "paperclip",
                    tint: KanameColor.success
                )
                Label("Hidden chain-of-thought is not exposed. Configured reasoning effort and provider-supplied summaries live under Usage.", systemImage: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(9)
                    .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                    .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var llmMessagesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Messages", detail: "Role-separated summaries · expand one record at a time")
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 5) {
                    messageRecord("System", index: "01", summary: "Policy and output contract", detail: "1,200 tokens", tint: KanameColor.warning)
                    messageRecord("User", index: "02", summary: "Mailbox projection and requested digest", detail: "3,820 tokens", tint: KanameColor.accent)
                    messageRecord("Assistant", index: "03", summary: "Requested two read-only tools", detail: "146 tokens", tint: KanameColor.blocked)
                    messageRecord("Tool", index: "04", summary: "Two linked results · both succeeded", detail: "1,074 tokens", tint: KanameColor.success)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 7) {
                    Label("Selected · User 02", systemImage: "bubble.left.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(KanameColor.accent)
                    Text("Summarize this frozen mailbox batch using only sender domain, subject category, received date, and the approved excerpt.")
                        .font(.caption)
                        .textSelection(.enabled)
                    Divider()
                    HStack {
                        evidenceFact("Origin", value: "Fan out")
                        Spacer()
                        evidenceFact("Content", value: "3,820 tokens")
                        Spacer()
                        evidenceFact("Redaction", value: "2 fields")
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
                .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var llmToolsAndUsageContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Tool calls", detail: "Inputs, results, and the messages they belong to remain linked")
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 6) {
                    toolCallRecord(
                        "lookup_sender_policy",
                        callID: "call_7K2",
                        input: "domain: example.co.jp",
                        result: "matched · protected_sender = false",
                        duration: "34 ms"
                    )
                    toolCallRecord(
                        "read_job_value",
                        callID: "call_8F1",
                        input: "key: digest.allowed_categories",
                        result: "6 categories · checkpoint 3c91…",
                        duration: "8 ms"
                    )
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Model & usage").font(.caption.weight(.bold))
                    usageRow("Configured model", value: "Pinned by workflow v3")
                    usageRow("Reasoning effort", value: "Medium · configured")
                    usageRow("Tokens", value: "6,240 in · 842 out")
                    usageRow("Tool calls", value: "2 / 2 succeeded")
                    usageRow("Provider summary", value: "Not supplied")
                    usageRow("Cost", value: "Shown when provider reports it")
                }
                .padding(10)
                .frame(width: 260, alignment: .topLeading)
                .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var llmUsageContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Model & usage", detail: "Configured values are separated from provider-reported values")
            HStack(alignment: .top, spacing: 10) {
                diagnosticPanel(
                    "Configuration",
                    rows: [
                        ("Model", "Pinned by workflow v3"),
                        ("Reasoning effort", "Medium"),
                        ("Temperature", "Workflow default"),
                        ("Tool policy", "Two read-only tools"),
                    ],
                    tint: KanameColor.blocked
                )
                diagnosticPanel(
                    "Provider report",
                    rows: [
                        ("Input tokens", "6,240"),
                        ("Output tokens", "842"),
                        ("Latency", "1.8 s"),
                        ("Reasoning summary", "Not supplied"),
                    ],
                    tint: KanameColor.accent
                )
            }
        }
    }

    private var rawStepEvidenceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Raw evidence", detail: "Complete records remain available for export and exact replay diagnostics")
            codePayload("Execution envelope", text: rawStepEnvelope)
            Label("Raw evidence is never the default view and retains explicit redaction markers.", systemImage: "eye.slash.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var rawStepEnvelope: String {
        "{ \"run_id\": \(selectedRun.id), \"node_id\": \"\(selectedRunStep.id)\", \"attempt\": 1, \"input_digest\": \"b840…19fc\", \"output_digest\": \"7d91…a8c2\" }"
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption.weight(.bold))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func inspectorStatusFact(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(tint)
        }
    }

    private func overviewTile(_ title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption.weight(.semibold)).lineLimit(1)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private func executionDataPanel(
        _ title: String,
        subtitle: String,
        tint: Color,
        rows: [(String, String, String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.caption.weight(.bold))
                Spacer()
                Text(subtitle).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.0).font(.system(.caption2, design: .monospaced).weight(.semibold))
                        Text(row.3).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(width: 106, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint)
                        .frame(width: 58, alignment: .leading)
                    Text(row.2).font(.caption2).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.25), lineWidth: 1) }
    }

    private func diagnosticPanel(
        _ title: String,
        rows: [(String, String)],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(tint)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.1).multilineTextAlignment(.trailing)
                }
                .font(.caption2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.24), lineWidth: 1) }
    }

    private func contextEnvelopeCard(
        _ title: String,
        detail: String,
        provenance: String,
        symbol: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text(detail).font(.caption2).lineLimit(2)
            Text(provenance).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private func messageRecord(
        _ role: String,
        index: String,
        summary: String,
        detail: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Text(index)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(role).font(.caption2.weight(.bold)).frame(width: 52, alignment: .leading)
            Text(summary).font(.caption2).lineLimit(1)
            Spacer(minLength: 4)
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .padding(7)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
    }

    private func toolCallRecord(
        _ name: String,
        callID: String,
        input: String,
        result: String,
        duration: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(name, systemImage: "wrench.and.screwdriver.fill")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(KanameColor.blocked)
                Text(callID).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Label("Succeeded", systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(KanameColor.success)
                Text(duration).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("INPUT").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                Text(input).font(.system(.caption2, design: .monospaced)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("RESULT").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                Text(result).font(.system(.caption2, design: .monospaced)).lineLimit(1)
            }
        }
        .padding(9)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(KanameColor.blocked.opacity(0.22), lineWidth: 1) }
    }

    private func usageRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption2)
    }

    @ViewBuilder
    private var runInspectorContent: some View {
        switch inspectorTab {
        case .data:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(selectedRunEdge == nil ? "Attempt data" : "Data at this boundary")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Picker("Data rendering", selection: $dataView) {
                        ForEach(AutomationRunDataView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                    Text("1 item · 2.4 KB").font(.caption2).foregroundStyle(.secondary)
                }
                dataPayload
            }
        case .storage:
            jobStorageInspector
        case .logs:
            runLogLine("22:31:04.218", "Loaded immutable input checkpoint", KanameColor.separator)
            runLogLine("22:31:04.231", "Validated schema case-context.v3", KanameColor.success)
            runLogLine("22:31:04.247", "Produced 1 item · digest 7d91…a8c2", KanameColor.accent)
        case .configuration:
            HStack(spacing: 28) {
                evidenceFact("Definition", value: "Workflow v\(selectedRun.version)")
                evidenceFact("Node", value: selectedRunEdge?.sourceID ?? selectedRunStep.id)
                evidenceFact("Retry", value: "Attempt 1 of 3")
                evidenceFact("Authority", value: selectedRunStep.authority)
                evidenceFact("Runtime", value: "Private local capability")
            }
        case .evidence:
            HStack(spacing: 28) {
                evidenceFact("Input digest", value: "b840…19fc")
                evidenceFact("Output digest", value: "7d91…a8c2")
                evidenceFact("Artifact", value: "context-snapshot.json")
                evidenceFact("Retention", value: selectedRun.expiry)
                evidenceFact("Redaction", value: "2 protected fields")
            }
        }
    }

    private var jobStorageInspector: some View {
        HStack(alignment: .top, spacing: 10) {
            storageInspectorColumn(
                "Job storage · #\(selectedRun.id)",
                subtitle: "Private to this job",
                symbol: "shippingbox.fill",
                tint: KanameColor.accent,
                rows: [
                    ("Values", "7 · 182 KB"),
                    ("Files", "3 · 48.0 MB"),
                    ("Lifetime", selectedRun.expiry),
                ]
            )
            storageInspectorColumn(
                "Recent changes",
                subtitle: "Committed by nodes",
                symbol: "arrow.triangle.2.circlepath",
                tint: KanameColor.success,
                rows: [
                    ("Run work type", "+ report-v3.xlsx"),
                    ("Compile context", "~ episode = 3"),
                    ("Verify all", "+ validation.json"),
                ]
            )
            storageInspectorColumn(
                "Workflow storage",
                subtitle: "Not deleted with this job",
                symbol: "externaldrive.fill",
                tint: KanameColor.blocked,
                rows: [
                    ("Durable values", "12"),
                    ("Promoted files", "4 · 86 MB"),
                    ("Scope", "All workflow versions"),
                ]
            )
        }
    }

    private func storageInspectorColumn(
        _ title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        rows: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.bold)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).fontWeight(.semibold).multilineTextAlignment(.trailing)
                }
                .font(.caption2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.24), lineWidth: 1) }
    }

    @ViewBuilder
    private var dataPayload: some View {
        if selectedRunEdge == nil {
            nodeDataComparison
        } else {
            checkpointDataPayload
        }
    }

    @ViewBuilder
    private var nodeDataComparison: some View {
        switch dataView {
        case .table:
            HStack(alignment: .top, spacing: 10) {
                comparisonPanel("Received", tint: KanameColor.separator) {
                    comparisonRow("episodes", value: "2")
                    comparisonRow("artifact", value: "report-v2.xlsx")
                    comparisonRow("instruction", value: "Use monthly totals")
                }
                comparisonPanel("Produced", tint: KanameColor.success) {
                    comparisonRow("episodes", value: "3", changed: true)
                    comparisonRow("artifact", value: "report-v3.xlsx", changed: true)
                    comparisonRow("current_intent", value: "correction", changed: true)
                }
            }
        case .json:
            HStack(alignment: .top, spacing: 10) {
                codePayload("Received", text: "{ \"episodes\": 2, \"artifact\": \"report-v2.xlsx\" }")
                codePayload("Produced", text: "{ \"episodes\": 3, \"artifact\": \"report-v3.xlsx\", \"current_intent\": \"correction\" }")
            }
        case .schema:
            HStack(alignment: .top, spacing: 10) {
                codePayload("Input schema", text: "episodes: [episode]\nartifact: file_reference")
                codePayload("Output schema", text: "episodes: [episode]\nartifact: file_reference\ncurrent_intent: enum")
            }
        }
    }

    @ViewBuilder
    private var checkpointDataPayload: some View {
        switch dataView {
        case .table:
            HStack(spacing: 0) {
                dataCell("case_id", value: "CASE-184")
                dataCell("episode", value: "3")
                dataCell("intent", value: "correction")
                dataCell("artifact", value: "report-v3.xlsx")
                dataCell("status", value: "verified")
            }
        case .json:
            codePayload("Checkpoint JSON", text: "{ \"case_id\": \"CASE-184\", \"episode\": 3, \"intent\": \"correction\", \"artifact\": \"report-v3.xlsx\", \"status\": \"verified\" }")
        case .schema:
            codePayload("Checkpoint schema", text: "case_id: string · episode: integer · intent: enum · artifact: file_reference · status: enum")
        }
    }

    private func comparisonPanel<Content: View>(
        _ title: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private func comparisonRow(_ field: String, value: String, changed: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(field).foregroundStyle(.secondary)
            Spacer()
            if changed {
                Image(systemName: "plus.circle.fill").foregroundStyle(KanameColor.success)
            }
            Text(value).lineLimit(1)
        }
        .font(.system(.caption2, design: .monospaced))
    }

    private func codePayload(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(KanameColor.accent)
                .textSelection(.enabled)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private func dataCell(_ field: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.canvas)
        .overlay { Rectangle().stroke(KanameColor.separator.opacity(0.8), lineWidth: 0.5) }
    }

    private func runLogLine(_ time: String, _ message: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(time).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(message).font(.system(.caption, design: .monospaced))
        }
    }

    private func edgeEndpointLabel(_ edge: AutomationCanvasEdge) -> String {
        let graph = selectedRun.pattern.graph
        let source = graph.steps.first(where: { $0.id == edge.sourceID })?.title ?? edge.sourceID
        let target = graph.steps.first(where: { $0.id == edge.targetID })?.title ?? edge.targetID
        return "\(source) → \(target) · immutable checkpoint"
    }

    private var retentionSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("History retention", systemImage: "clock.arrow.circlepath")
                .font(.title3.weight(.semibold))
            Text("Default for new runs of this workflow")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Retention", selection: $retention) {
                ForEach(AutomationRunRetention.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Divider()
            retentionExplanation
            Divider()
            Label("Unresolved runs are protected", systemImage: "shield.fill")
                .foregroundStyle(KanameColor.warning)
            Text("Waiting, failed, or unknown outcomes remain until resolved or manually deleted, even when successful runs are removed immediately.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 24)
            Text("Storage estimate").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text("18 runs · 42 MB").font(.caption.weight(.semibold))
            Button("Delete selected…", systemImage: "trash", role: .destructive) {}
                .buttonStyle(.bordered)
                .disabled(true)
        }
        .padding(20)
        .frame(maxWidth: 720, minHeight: 520, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var retentionExplanation: some View {
        switch retention {
        case .thirtyDays:
            Text("Successful and settled runs are deleted 30 days after completion.")
        case .deleteAfterSuccess:
            Text("Successful run detail is deleted after its final receipt is reconciled.")
        case .forever:
            Text("Run history remains until you delete it manually.")
        }
    }

    private var deleteJobConfirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "trash.fill")
                    .foregroundStyle(KanameColor.danger)
                    .frame(width: 34, height: 34)
                    .background(KanameColor.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete job #\(selectedRun.id)?").font(.title3.weight(.bold))
                    Text("This cannot be undone").font(.caption).foregroundStyle(KanameColor.danger)
                }
                Spacer()
                Button("Close", systemImage: "xmark") {
                    showsDeleteJobConfirmation = false
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
            }

            Text("The job record and everything isolated inside its storage boundary will be removed together.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                deletionRow("Run history and trace", value: "1 job", deleted: true)
                Divider()
                deletionRow("Job values", value: "7 · 182 KB", deleted: true)
                Divider()
                deletionRow("Job files", value: "3 · 48.0 MB", deleted: true)
                Divider()
                deletionRow("Workflow storage", value: "4 files · 86 MB", deleted: false)
            }
            .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 9))

            Label(
                "Promoted files and long-term values remain in workflow storage.",
                systemImage: "externaldrive.fill.badge.checkmark"
            )
            .font(.caption)
            .foregroundStyle(KanameColor.blocked)

            HStack {
                Spacer()
                Button("Cancel") {
                    showsDeleteJobConfirmation = false
                }
                .buttonStyle(.bordered)
                Button("Delete job and job storage", role: .destructive) {}
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(KanameColor.danger.opacity(0.45), lineWidth: 1) }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }

    private func deletionRow(_ label: String, value: String, deleted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: deleted ? "trash" : "lock.shield.fill")
                .foregroundStyle(deleted ? KanameColor.danger : KanameColor.blocked)
                .frame(width: 18)
            Text(label).font(.caption.weight(.semibold))
            Spacer()
            Text(deleted ? "Delete · \(value)" : "Keep · \(value)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(deleted ? KanameColor.danger : KanameColor.blocked)
        }
        .padding(10)
    }

    private func evidenceFact(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium))
        }
    }
}
