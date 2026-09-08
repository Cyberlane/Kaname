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

struct DesktopProjectsView: View {
    @ObservedObject var model: DesktopAppModel
    let createProject: () -> Void
    let openProject: (String) -> Void
    let startConversation: (String) -> Void
    let openThread: (String) -> Void
    @State private var query = ""
    @State private var showsArchived = false

    private var projects: [DesktopProject] {
        model.projects(matching: query, includeArchived: showsArchived)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Projects",
                    detail: "Repository, instruction, skill, and knowledge boundaries",
                    symbol: DesktopDestination.projects.symbol
                ) {
                    Button("New project", systemImage: "folder.badge.plus", action: createProject)
                        .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 12) {
                    Label {
                        TextField("Search projects", text: $query)
                            .textFieldStyle(.plain)
                    } icon: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 11))

                    Picker("Project state", selection: $showsArchived) {
                        Text("Active").tag(false)
                        Text("Archived").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }

                if projects.isEmpty {
                    EmptyPanel(
                        symbol: showsArchived ? "archivebox" : "folder",
                        title: query.isEmpty ? (showsArchived ? "No archived projects" : "No active projects") : "No matching projects",
                        detail: query.isEmpty
                            ? "Projects keep repository, instruction, skill, and knowledge context deliberate."
                            : "Try a project name, purpose, path, or instruction reference."
                    )
                    .frame(minHeight: 280)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14)], spacing: 14) {
                        ForEach(projects) { project in
                            ProjectCard(
                                project: project,
                                threads: model.activeThreads.filter { $0.projectID == project.id },
                                openProject: { openProject(project.id) },
                                startConversation: { startConversation(project.id) },
                                openThread: openThread
                            )
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.canvas)
    }
}

struct DesktopProjectOverview: View {
    @ObservedObject var model: DesktopAppModel
    let project: DesktopProject
    let startConversation: () -> Void
    let openThread: (String) -> Void
    @State private var showsEditor = false
    @State private var showsArchiveConfirmation = false

    private var threads: [DesktopThread] {
        model.snapshot.threads
            .filter { $0.projectID == project.id && $0.attention != .archived }
            .sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }
    }

    private var threadIDs: Set<String> { Set(threads.map(\.id)) }

    private var runs: [DesktopProviderRunRecord] {
        model.snapshot.operations.providerRuns.filter { run in
            run.threadID.map(threadIDs.contains) == true
        }
    }

    private var artifacts: [DesktopArtifactRecord] {
        model.snapshot.operations.artifacts.filter { artifact in
            artifact.threadID.map(threadIDs.contains) == true
        }
    }

    private var workspaces: [DesktopGitWorkspace] {
        model.snapshot.domains.gitWorkspaces.filter { $0.projectID == project.id }
    }

    private var knowledgeSources: [DesktopKnowledgeSource] {
        let selected = Set(project.context.knowledgeSourceIDs)
        return model.snapshot.domains.knowledgeSources.filter { selected.contains($0.id) }
    }

    private var skills: [DesktopSkillRecord] {
        let selected = Set(project.context.skillIDs)
        return model.snapshot.domains.skills.filter { selected.contains($0.id) }
    }

    private var attentionCount: Int {
        threads.filter { $0.attention == .needsResponse || $0.attention == .needsApproval || $0.unread }.count
    }

    private var hasActiveRun: Bool {
        runs.contains { $0.state == .running || $0.state == .awaitingApproval }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: project.name,
                    detail: project.summary.isEmpty ? "No purpose recorded yet." : project.summary,
                    symbol: "folder.fill"
                ) {
                    HStack(spacing: 10) {
                        Button("Edit context", systemImage: "slider.horizontal.3") { showsEditor = true }
                            .buttonStyle(.bordered)
                        if project.archivedAtUnixMillis == nil {
                            Button("New conversation", systemImage: "square.and.pencil", action: startConversation)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Restore project", systemImage: "arrow.uturn.backward") {
                                model.setProjectArchived(id: project.id, archived: false)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                if project.archivedAtUnixMillis != nil {
                    BoundaryCallout(
                        title: "Archived project",
                        detail: "Its context remains inspectable and recoverable. Restore it before starting new work."
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ProjectMetric(title: "Conversations", value: "\(threads.count)", symbol: "bubble.left.and.bubble.right", tint: KanameColor.accent)
                    ProjectMetric(title: "Needs you", value: "\(attentionCount)", symbol: "person.crop.circle.badge.exclamationmark", tint: attentionCount == 0 ? KanameColor.success : KanameColor.warning)
                    ProjectMetric(title: "Provider runs", value: "\(runs.count)", symbol: "cpu", tint: KanameColor.accent)
                    ProjectMetric(title: "Artifacts", value: "\(artifacts.count)", symbol: "doc.on.doc", tint: KanameColor.blocked)
                }

                HStack(alignment: .top, spacing: 14) {
                    DesktopProjectSection(title: "Execution context", symbol: "scope") {
                        ProjectContextFact(label: "Default kind", value: project.context.defaultKind.label)
                        ProjectContextFact(label: "Provider", value: project.context.defaultProvider)
                        ProjectContextFact(label: "Model", value: project.context.defaultModel)
                        if let path = project.path {
                            ProjectContextFact(label: "Primary workspace", value: path, monospaced: true)
                        }
                        if workspaces.isEmpty && project.path == nil {
                            ProjectEmptyContext(text: "No repository or workspace linked")
                        } else {
                            ForEach(workspaces) { workspace in
                                ProjectSourceRow(
                                    symbol: "externaldrive.fill",
                                    title: workspace.name,
                                    detail: "\(workspace.branch) · \(workspace.remoteSummary)",
                                    status: workspace.status.label
                                )
                            }
                        }
                    }

                    DesktopProjectSection(title: "Instructions", symbol: "text.book.closed") {
                        if project.context.instructionReferences.isEmpty {
                            ProjectEmptyContext(text: "No instruction source linked")
                        } else {
                            ForEach(project.context.instructionReferences, id: \.self) { reference in
                                ProjectSourceRow(
                                    symbol: "doc.text",
                                    title: reference,
                                    detail: "Included deliberately",
                                    status: "Linked"
                                )
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    DesktopProjectSection(title: "Knowledge", symbol: "books.vertical.fill") {
                        if knowledgeSources.isEmpty {
                            ProjectEmptyContext(text: "No knowledge source linked")
                        } else {
                            ForEach(knowledgeSources) { source in
                                ProjectSourceRow(
                                    symbol: source.kind == .obsidian ? "diamond.fill" : "folder.fill",
                                    title: source.name,
                                    detail: source.scope,
                                    status: source.status.label
                                )
                            }
                        }
                    }

                    DesktopProjectSection(title: "Skills & tools", symbol: "hammer.fill") {
                        if skills.isEmpty {
                            ProjectEmptyContext(text: "No project skill linked")
                        } else {
                            ForEach(skills) { skill in
                                ProjectSourceRow(
                                    symbol: skill.kind == .hook ? "point.3.connected.trianglepath.dotted" : "hammer",
                                    title: skill.name,
                                    detail: skill.scope,
                                    status: skill.enabled ? "Enabled" : "Disabled"
                                )
                            }
                        }
                    }
                }

                DesktopProjectSection(title: "Recent conversations", symbol: "clock.arrow.circlepath") {
                    if threads.isEmpty {
                        ProjectEmptyContext(text: "No active conversation in this project")
                    } else {
                        ForEach(threads.prefix(8)) { thread in
                            Button { openThread(thread.id) } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(thread.attention.tint).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(thread.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text(thread.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(thread.kind.label).font(.caption2).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if project.archivedAtUnixMillis == nil {
                    Divider()
                    Button("Archive project", systemImage: "archivebox") { showsArchiveConfirmation = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(hasActiveRun ? .secondary : KanameColor.danger)
                        .disabled(hasActiveRun)
                        .help(hasActiveRun ? "Finish or interrupt active runs before archiving" : "Archive this project and its conversations")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.canvas)
        .sheet(isPresented: $showsEditor) {
            DesktopProjectEditor(model: model, project: project)
        }
        .confirmationDialog(
            "Archive \(project.name)?",
            isPresented: $showsArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Archive project and conversations", role: .destructive) {
                model.setProjectArchived(id: project.id, archived: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is recoverable. Linked context remains local and inspectable.")
        }
    }
}

private struct DesktopProjectEditor: View {
    @ObservedObject var model: DesktopAppModel
    let project: DesktopProject
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var path: String
    @State private var summary: String
    @State private var instructionText: String
    @State private var knowledgeSourceIDs: Set<String>
    @State private var skillIDs: Set<String>
    @State private var allowsCrossProjectRecall: Bool
    @State private var defaultKind: DesktopWorkKind
    @State private var defaultProvider: String
    @State private var defaultModel: String
    @State private var saveError: String?

    init(model: DesktopAppModel, project: DesktopProject) {
        self.model = model
        self.project = project
        _name = State(initialValue: project.name)
        _path = State(initialValue: project.path ?? "")
        _summary = State(initialValue: project.summary)
        _instructionText = State(initialValue: project.context.instructionReferences.joined(separator: "\n"))
        _knowledgeSourceIDs = State(initialValue: Set(project.context.knowledgeSourceIDs))
        _skillIDs = State(initialValue: Set(project.context.skillIDs))
        _allowsCrossProjectRecall = State(initialValue: project.context.allowsCrossProjectRecall)
        _defaultKind = State(initialValue: project.context.defaultKind)
        _defaultProvider = State(initialValue: project.context.defaultProvider)
        _defaultModel = State(initialValue: project.context.defaultModel)
    }

    private var instructions: [String] {
        instructionText.split(whereSeparator: \Character.isNewline).map(String.init)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Purpose", text: $summary, axis: .vertical).lineLimit(2...5)
                    TextField("Primary workspace path", text: $path)
                }

                Section("Conversation defaults") {
                    Picker("Kind", selection: $defaultKind) {
                        ForEach(DesktopWorkKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Provider", text: $defaultProvider)
                    TextField("Model", text: $defaultModel)
                    Text("Defaults remove setup friction; every run still shows its actual provider, model, context, and authority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Instruction references") {
                    TextEditor(text: $instructionText)
                        .font(.body.monospaced())
                        .frame(minHeight: 90)
                    Text("One repository-relative or deliberately scoped reference per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Knowledge") {
                    if model.snapshot.domains.knowledgeSources.isEmpty {
                        Text("No knowledge sources are available.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.snapshot.domains.knowledgeSources) { source in
                            Toggle(isOn: membership(source.id, in: $knowledgeSourceIDs)) {
                                VStack(alignment: .leading) {
                                    Text(source.name)
                                    Text(source.scope).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel(source.name)
                            .accessibilityValue("\(source.kind.label), \(source.scope), \(source.status.label)")
                        }
                    }
                    Toggle("Allow accepted cross project recall", isOn: $allowsCrossProjectRecall)
                        .accessibilityHint("Makes explicitly accepted shared knowledge from other projects available to this project's history tools.")
                    Text("Only reconciled knowledge from a source this project selects can be recalled across projects.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Skills & tools") {
                    if model.snapshot.domains.skills.isEmpty {
                        Text("No skills or tools are available.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.snapshot.domains.skills) { skill in
                            Toggle(isOn: membership(skill.id, in: $skillIDs)) {
                                VStack(alignment: .leading) {
                                    Text(skill.name)
                                    Text("\(skill.kind.label) · \(skill.scope)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel(skill.name)
                            .accessibilityValue("\(skill.kind.label), \(skill.scope), \(skill.enabled ? "enabled" : "disabled")")
                        }
                    }
                }

                Section("Review") {
                    LabeledContent("Instructions", value: "\(instructions.count)")
                    LabeledContent("Knowledge sources", value: "\(knowledgeSourceIDs.count)")
                    LabeledContent("Skills & tools", value: "\(skillIDs.count)")
                    Text("Saving replaces this project's context selection only. It does not start a provider, read a source, or grant write authority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(KanameColor.danger)
                    }
                }
            }
            .formStyle(.grouped)
            .desktopAdaptiveSheet(idealWidth: 720, idealHeight: 720)
            .navigationTitle("Edit \(project.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save context", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func membership(_ id: String, in selection: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(id) },
            set: { enabled in
                if enabled { selection.wrappedValue.insert(id) }
                else { selection.wrappedValue.remove(id) }
            }
        )
    }

    private func save() {
        let context = DesktopProjectContext(
            instructionReferences: instructions,
            knowledgeSourceIDs: Array(knowledgeSourceIDs).sorted(),
            skillIDs: Array(skillIDs).sorted(),
            allowsCrossProjectRecall: allowsCrossProjectRecall,
            defaultKind: defaultKind,
            defaultProvider: defaultProvider,
            defaultModel: defaultModel
        )
        if model.updateProject(id: project.id, name: name, path: path, summary: summary, context: context) {
            dismiss()
        } else {
            saveError = "Review the project name, paths, and defaults before saving."
        }
    }
}

private struct DesktopProjectSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            Divider()
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 15))
    }
}

private struct ProjectMetric: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title2.weight(.bold))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ProjectContextFact: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct ProjectSourceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(KanameColor.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(status).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

private struct ProjectEmptyContext: View {
    let text: String

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
    }
}
