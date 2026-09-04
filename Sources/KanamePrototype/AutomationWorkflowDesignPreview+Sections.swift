import KanameDesktop
import KanameLocalCore
import KanameProtocol
import KanamePrototypeUI
import KanameWorkflowHost
import SwiftUI
import KanameDesignSystem

/// Run history reads the durable Rust workflow projection and nothing else. The
/// in-memory desktop snapshot is a design-time preview of workflow structure,
/// not run evidence, so it is deliberately not offered as a second timeline
/// here: a run either has durable evidence or its absence is stated outright.
struct AutomationLiveRunsView: View {
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

struct AutomationComponentsView: View {
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

struct AutomationReadinessView: View {
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
