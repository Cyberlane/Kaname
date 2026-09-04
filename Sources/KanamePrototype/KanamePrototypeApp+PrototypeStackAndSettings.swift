import Foundation
import SwiftUI
import KanameConnectivity
import KanameDesignSystem
import KanameDesktop
import KanameDomain
import KanameFixtures
import KanamePrototypeUI
#if os(macOS)
import AppKit
import Darwin
#endif

struct StackPrototypeView: View {
    @State private var selectedLayerID = StackSample.layers[1].id
    @State private var agentDraft = ""
    @State private var draftedAgentTask: String?

    private var selectedLayer: StackLayer {
        StackSample.layers.first { $0.id == selectedLayerID } ?? StackSample.layers[0]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PhaseBanner()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Stack-aware review")
                            .font(.largeTitle.weight(.bold))
                        Text("A stack is a dependency graph with layer-specific evidence, not a flat list of pull requests.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Open Cyberlane/Kaname", destination: URL(string: "https://github.com/Cyberlane/Kaname")!)
                        .font(.subheadline.weight(.semibold))
                }

                Text("Fixture mode: these layers are illustrative. A live GitHub adapter will replace them with actual pull-request URLs, checks, logs, reviews, and stack state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(StackSample.layers.enumerated()), id: \.element.id) { index, layer in
                            StackLayerRow(
                                layer: layer,
                                isSelected: selectedLayerID == layer.id,
                                showsConnector: index < StackSample.layers.count - 1
                            ) {
                                selectedLayerID = layer.id
                            }
                        }
                    }
                    .frame(maxWidth: 430, alignment: .leading)

                    StackLayerDetail(layer: selectedLayer)
                        .frame(maxWidth: 540, alignment: .leading)
                }

                StackAgentTaskComposer(
                    draft: $agentDraft,
                    draftedTask: $draftedAgentTask,
                    layer: selectedLayer
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StackLayer: Identifiable {
    let id: String
    let title: String
    let branch: String
    let pullRequest: String
    let checks: String
    let evidence: String
    let status: StackLayerStatus
}

private enum StackLayerStatus: String {
    case ready
    case review
    case blocked

    var tint: Color {
        switch self {
        case .ready: KanameColor.success
        case .review: KanameColor.warning
        case .blocked: KanameColor.danger
        }
    }

    var displayName: String { rawValue.capitalized }
}

private enum StackSample {
    static let layers: [StackLayer] = [
        StackLayer(
            id: "contracts",
            title: "Define search contracts",
            branch: "feat/search-contracts",
            pullRequest: "PR #18",
            checks: "4 checks passing",
            evidence: "Domain contract and deterministic fixtures reviewed.",
            status: .ready
        ),
        StackLayer(
            id: "adapter",
            title: "Add fake search adapter",
            branch: "feat/fake-search-adapter",
            pullRequest: "PR #19",
            checks: "1 review requested",
            evidence: "Depends on #18. The provider-native mapping stays visible here.",
            status: .review
        ),
        StackLayer(
            id: "surface",
            title: "Show search evidence",
            branch: "feat/search-evidence-surface",
            pullRequest: "PR #20",
            checks: "Waiting on #19",
            evidence: "May not merge until the lower adapter layer is accepted.",
            status: .blocked
        ),
    ]
}

private struct StackLayerRow: View {
    let layer: StackLayer
    let isSelected: Bool
    let showsConnector: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(layer.status.tint)
                        .frame(width: 12, height: 12)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(layer.title)
                                .font(.headline)
                            Spacer()
                            Text(layer.status.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(layer.status.tint)
                        }
                        Text("\(layer.pullRequest) · \(layer.branch)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(
                    isSelected ? layer.status.tint.opacity(0.14) : Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .buttonStyle(.plain)

            if showsConnector {
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 2, height: 24)
                    .padding(.leading, 19)
            }
        }
    }
}

private struct StackLayerDetail: View {
    let layer: StackLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(layer.pullRequest)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                KanameStatusBadge(
                    layer.status.attention.legacyStatusPresentation,
                    density: .compact
                )
            }
            Text(layer.title)
                .font(.title2.weight(.bold))
            Text(layer.evidence)
                .foregroundStyle(.secondary)
            Divider()
            LabeledContent("Branch", value: layer.branch)
            LabeledContent("Checks", value: layer.checks)
            LabeledContent("Merge rule", value: "Bottom-up dependency order")
            LabeledContent("Connection", value: "Thread, plan, worktree, and evidence attach to this layer")
            Divider()
            StackCheckList(layerID: layer.id)
        }
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct StackCheck: Identifiable {
    let id: String
    let name: String
    let status: StackLayerStatus
    let summary: String
    let logExcerpt: String
}

private enum StackCheckFixture {
    static func checks(for layerID: String) -> [StackCheck] {
        switch layerID {
        case "contracts":
            [
                StackCheck(
                    id: "contracts-tests",
                    name: "Swift unit tests",
                    status: .ready,
                    summary: "4 checks passed in 1.1 s",
                    logExcerpt: "ThreadProjectionTests: all deterministic replay checks passed."
                ),
                StackCheck(
                    id: "contracts-build",
                    name: "iOS build",
                    status: .ready,
                    summary: "generic iOS target built",
                    logExcerpt: "KanamePrototype compiled for iOS 16.0."
                ),
            ]
        case "adapter":
            [
                StackCheck(
                    id: "adapter-review",
                    name: "Code review",
                    status: .review,
                    summary: "one comment needs response",
                    logExcerpt: "Question: should unknown provider events be retained as opaque payloads?"
                ),
                StackCheck(
                    id: "adapter-tests",
                    name: "Contract tests",
                    status: .ready,
                    summary: "12 checks passed",
                    logExcerpt: "Adapter capabilities and degraded states match the fixture contract."
                ),
            ]
        default:
            [
                StackCheck(
                    id: "surface-dependency",
                    name: "Dependency gate",
                    status: .blocked,
                    summary: "waiting for PR #19 review",
                    logExcerpt: "This layer cannot merge until the adapter layer is accepted."
                ),
                StackCheck(
                    id: "surface-ui",
                    name: "Native UI test",
                    status: .review,
                    summary: "not run while dependency is blocked",
                    logExcerpt: "Run the focused native UI suite after the lower layer is current."
                ),
            ]
        }
    }
}

private struct StackCheckList: View {
    let layerID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CI, review, and diagnostics")
                .font(.headline)
            ForEach(StackCheckFixture.checks(for: layerID)) { check in
                StackCheckRow(check: check)
            }
        }
    }
}

private struct StackCheckRow: View {
    let check: StackCheck
    @State private var showsLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(check.status.tint).frame(width: 8, height: 8)
                Text(check.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(check.status.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(check.status.tint)
            }
            Text(check.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(showsLog ? "Hide details" : "Show diagnostic") {
                showsLog.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            if showsLog {
                Text(check.logExcerpt)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(check.status.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct StackAgentTaskComposer: View {
    @Binding var draft: String
    @Binding var draftedTask: String?
    let layer: StackLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a scoped agent conversation")
                .font(.headline)
            Text("Useful actions include explaining a failed check, proposing a minimal fix, reviewing a dependency, or preparing a re-run plan. The fixture only drafts the task locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Explain check") {
                    draft = "Explain the current CI and review state for \(layer.pullRequest)."
                }
                .buttonStyle(.bordered)
                Button("Propose fix") {
                    draft = "Propose the smallest safe fix for the blocked or failing evidence on \(layer.pullRequest)."
                }
                .buttonStyle(.bordered)
                Button("Plan re-run") {
                    draft = "List the checks to re-run for \(layer.pullRequest), their order, and expected evidence."
                }
                .buttonStyle(.bordered)
            }
            HStack {
                TextField("Ask an agent about this stack layer", text: $draft)
                Button("Draft task") {
                    let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedDraft.isEmpty else { return }
                    draftedTask = trimmedDraft
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            if let draftedTask {
                Text("Local draft ready to attach to a new conversation: \(draftedTask)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance
    case providers
    case projects
    case integrations
    case schedules
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "General & appearance"
        case .providers: "Providers & models"
        case .projects: "Projects & workspaces"
        case .integrations: "Integrations & accounts"
        case .schedules: "Schedules & notifications"
        case .privacy: "Privacy, security & data"
        case .about: "About, skills & updates"
        }
    }

    var symbolName: String {
        switch self {
        case .appearance: "paintpalette"
        case .providers: "cpu"
        case .projects: "folder"
        case .integrations: "puzzlepiece.extension"
        case .schedules: "clock"
        case .privacy: "lock.shield"
        case .about: "info.circle"
        }
    }
}

struct SettingsModal: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.64)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    isPresented = false
                }

            SettingsPrototypeView {
                isPresented = false
            }
            .frame(maxWidth: 1_080, maxHeight: 720)
            .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(KanameColor.separator, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
            .padding(40)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture { }
            .accessibilityAddTraits(.isModal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#if os(macOS)
        .onExitCommand {
            isPresented = false
        }
#endif
    }
}

private struct SettingsPrototypeView: View {
    let close: () -> Void
    @AppStorage("kaname.fixture.settings.selected-category") private var selectedCategoryRaw = SettingsCategory.appearance.rawValue

    private var selectedCategory: SettingsCategory {
        SettingsCategory(rawValue: selectedCategoryRaw) ?? .appearance
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List {
                    Section("Kaname settings") {
                        ForEach(SettingsCategory.allCases) { category in
                            Button {
                                selectedCategoryRaw = category.rawValue
                            } label: {
                                Label(category.title, systemImage: category.symbolName)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .font(selectedCategory == category ? .body.weight(.semibold) : .body)
                                    .foregroundStyle(selectedCategory == category ? KanameColor.accent : KanameColor.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(KanameColor.surface)
                .frame(maxHeight: .infinity)

                Divider()
                Button {
                    close()
                } label: {
                    Label("Return to Kaname", systemImage: "arrow.left")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(KanameColor.accent)
                .padding(14)
            }
            .background(KanameColor.surface)
            .frame(minWidth: 230, idealWidth: 250, maxWidth: 280)

            Divider()

            SettingsDetail(category: selectedCategory, close: close)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KanameColor.canvas)
        }
        .frame(minWidth: 900, minHeight: 640)
    }
}

private struct SettingsDetail: View {
    let category: SettingsCategory
    let close: () -> Void
    @State private var theme = "Nord Dark"
    @State private var density = "Comfortable"
    @State private var inspectorVisible = true
    @State private var reduceMotion = false
    @State private var defaultProvider = "Choose per project"
    @State private var showProviderUsage = true
    @State private var networkToolApproval = true
    @State private var workspacePolicy = "Isolated worktree"
    @State private var requireGitReview = true
    @State private var suggestKnowledgeUpdate = true
    @State private var missedRunPolicy = "Skip / do nothing"
    @State private var scheduledNotifications = true
    @State private var maximumConcurrentRuns = 1
    @State private var externalCommunicationApproval = true
    @State private var keepAuditTrail = true
    @State private var retention = "90 days"
    @State private var localNotice: String?

    private var subtitle: String {
        switch category {
        case .appearance: "Personalize the Kaname workspace. Nord Dark remains your default; other themes are an OSS preference, not a different product state."
        case .providers: "Provider defaults are capability-aware and remain visible in the work they affect. This fixture has no authenticated provider."
        case .projects: "These defaults apply when creating a project; project-specific instructions and authority remain inspectable before a task runs."
        case .integrations: "Connections stay account-scoped and require an explicit setup flow. This prototype never opens an account or requests a credential."
        case .schedules: "Choose global defaults for durable scheduled work. Each task still shows its own time zone, trigger, authority, and missed-run policy."
        case .privacy: "Privacy controls establish safe defaults. They never bypass approval, disclose a secret, or join previously separate contexts."
        case .about: "Inspect the fixture's local state, planned skills provenance, and update behaviour without performing a network operation."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(category.title, systemImage: category.symbolName)
                        .font(.title.weight(.bold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                    Text("Phase 0 controls affect local preview state only.")
                        .font(.caption)
                        .foregroundStyle(KanameColor.accent)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Close Settings")
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Form {
                controls
            }
            .formStyle(.grouped)

            if let localNotice {
                Text(localNotice)
                    .font(.caption)
                    .foregroundStyle(KanameColor.accent)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch category {
        case .appearance:
            Section("Theme") {
                Picker("Appearance", selection: $theme) {
                    Text("Nord Dark").tag("Nord Dark")
                    Text("Nord Light").tag("Nord Light")
                    Text("Follow system").tag("Follow system")
                }
                Picker("Workspace density", selection: $density) {
                    Text("Comfortable").tag("Comfortable")
                    Text("Compact").tag("Compact")
                }
            }
            Section("Workspace") {
                Toggle("Show context inspector by default", isOn: $inspectorVisible)
                Toggle("Reduce nonessential motion", isOn: $reduceMotion)
            }
        case .providers:
            Section("Defaults") {
                Picker("New coding conversations", selection: $defaultProvider) {
                    Text("Choose per project").tag("Choose per project")
                    Text("Claude — when available").tag("Claude — when available")
                    Text("Codex — when available").tag("Codex — when available")
                    Text("OpenCode — when available").tag("OpenCode — when available")
                }
                Toggle("Show provider usage in conversations", isOn: $showProviderUsage)
                Toggle("Request approval before a new network tool", isOn: $networkToolApproval)
            }
            Section("Connection state") {
                LabeledContent("Fixture provider", value: "No live account")
                Button("Review provider setup requirements") {
                    localNotice = "Provider setup is intentionally not implemented in this local fixture."
                }
            }
        case .projects:
            Section("New project defaults") {
                Picker("Workspace policy", selection: $workspacePolicy) {
                    Text("Isolated worktree").tag("Isolated worktree")
                    Text("Read-only review").tag("Read-only review")
                    Text("No repository").tag("No repository")
                }
                Toggle("Require review before Git branch actions", isOn: $requireGitReview)
                Toggle("Propose a knowledge update after acceptance", isOn: $suggestKnowledgeUpdate)
            }
            Section("Instructions and skills") {
                LabeledContent("Repository instructions", value: "Read before task start")
                LabeledContent("Project skills", value: "Scoped and auditable")
            }
        case .integrations:
            Section("Connections") {
                IntegrationSettingsRow(name: "GitHub", detail: "Not connected", action: { localNotice = "GitHub connection setup is unavailable in the fixture." })
                IntegrationSettingsRow(name: "Obsidian", detail: "No vault operation", action: { localNotice = "Obsidian access is unavailable in the fixture." })
                IntegrationSettingsRow(name: "Gmail", detail: "No account connected", action: { localNotice = "Gmail setup is unavailable in the fixture." })
                IntegrationSettingsRow(name: "Calendars", detail: "No account connected", action: { localNotice = "Calendar setup is unavailable in the fixture." })
            }
            Section("Safety") {
                Text("Connection setup will show the account, scope, data egress, permission, and recovery path before it stores a provider-managed reference.")
            }
        case .schedules:
            Section("Scheduled work") {
                Picker("Missed run default", selection: $missedRunPolicy) {
                    Text("Skip / do nothing").tag("Skip / do nothing")
                    Text("Run once when available").tag("Run once when available")
                    Text("Catch up").tag("Catch up")
                }
                Stepper("Maximum concurrent runs: \(maximumConcurrentRuns)", value: $maximumConcurrentRuns, in: 1...4)
                Toggle("Notify when scheduled work needs attention", isOn: $scheduledNotifications)
            }
            Section("Always per task") {
                LabeledContent("Time zone", value: "Explicit")
                LabeledContent("Run history", value: "Durable")
            }
        case .privacy:
            Section("Confirmation defaults") {
                Toggle("Confirm external communication", isOn: $externalCommunicationApproval)
                Toggle("Keep an inspectable local audit trail", isOn: $keepAuditTrail)
                Picker("Operational-data retention", selection: $retention) {
                    Text("30 days").tag("30 days")
                    Text("90 days").tag("90 days")
                    Text("1 year").tag("1 year")
                }
            }
            Section("Secrets and context") {
                LabeledContent("Secrets", value: "Provider-managed references only")
                LabeledContent("Context sharing", value: "Explicit attachments only")
            }
        case .about:
            Section("Fixture") {
                LabeledContent("Phase", value: "0 — deterministic local fixture")
                LabeledContent("Network", value: "No connection attempted")
                LabeledContent("Skills", value: "No runtime skill loaded")
            }
            Section("Diagnostics") {
                Button("Prepare local diagnostics summary") {
                    localNotice = "Local diagnostics summary prepared in the UI only; nothing was copied or sent."
                }
            }
        }
    }
}

private struct IntegrationSettingsRow: View {
    let name: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set up…", action: action)
                .buttonStyle(.bordered)
        }
    }
}

struct ContextInspector: View {
    let fixture: Phase0Fixture

    var body: some View {
        let projection = try? fixture.makeProjection()

        List {
            Section("Selected context") {
                LabeledContent("Workspace", value: fixture.thread.workspaceKind.displayName)
                LabeledContent("Task", value: fixture.task.title)
                LabeledContent("Provider", value: fixture.providerSession.provider)
                LabeledContent("Native session", value: fixture.providerSession.nativeSessionID ?? "not exposed")
            }
            Section("State projection") {
                LabeledContent("Attention", value: projection?.attention.displayName ?? "Unknown")
                LabeledContent("Run", value: projection?.taskState.displayName ?? "Unknown")
                LabeledContent("Event cursor", value: "\(projection?.latestSequence ?? 0)")
            }
            Section("Trust boundary") {
                Text("Fixture-only: no provider, repository, account, vault, or notification service is contacted.")
                Text("Provider completion and accepted work are separate states.")
            }
        }
        .navigationTitle("Inspector")
    }
}

struct LiveCodexContextInspector: View {
    var body: some View {
        List {
            Section("Execution contract") {
                LabeledContent("Provider", value: "Codex app-server")
                LabeledContent("Model", value: "GPT-5.6 Terra")
                LabeledContent("Reasoning", value: "Extra high")
                LabeledContent("Workspace", value: "Selected in this review")
            }
            Section("Isolation") {
                LabeledContent("Filesystem", value: "Selected worktree only")
                LabeledContent("Network", value: "Denied during write runs")
                LabeledContent("MCP servers", value: "None")
                LabeledContent("Apps", value: "Disabled")
            }
            Section("Authority") {
                Text("The local journal owns approvals and review decisions. Provider completion never accepts work automatically.")
                Text("Only the context explicitly selected in the coding surface is sent to Codex.")
            }
        }
        .navigationTitle("Live boundary")
    }
}

extension TaskState {
    var displayName: String {
        switch self {
        case .notStarted: "Not started"
        case .queued: "Queued"
        case .starting: "Starting"
        case .running: "Running"
        case .waitingForUser: "Waiting for you"
        case .completed: "Completed"
        case .accepted: "Accepted"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }
}

private extension StackLayerStatus {
    var attention: AttentionState {
        switch self {
        case .ready: .none
        case .review: .needsReview
        case .blocked: .failed
        }
    }
}
