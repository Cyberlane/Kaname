import KanameDesktop
import KanameLocalCore
import KanameProtocol
import KanamePrototypeUI
import KanameWorkflowHost
import SwiftUI
import KanameDesignSystem

struct AutomationWorkflowStarterTemplate: Identifiable {
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
    let deepLink: DesktopAutomationDeepLink?

    init(
        model: DesktopAppModel,
        scheduler: DesktopAutomationSchedulerViewModel,
        integrations: DesktopPersonalIntegrationViewModel,
        deepLink: DesktopAutomationDeepLink? = nil
    ) {
        self.model = model
        self.scheduler = scheduler
        self.integrations = integrations
        self.deepLink = deepLink
        _section = State(initialValue: deepLink == nil ? Section.initial(arguments: CommandLine.arguments) : .runs)
    }

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
                    AutomationLiveRunsView(
                        initialRunID: deepLink?.runID,
                        initialEffectID: deepLink?.effectID
                    )
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
        .onChange(of: deepLink) { link in
            guard link != nil else { return }
            section = .runs
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
                title: "No saved workflow designs",
                detail: "Published workflows can still appear in Run history. Create or import a design to edit it here."
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
