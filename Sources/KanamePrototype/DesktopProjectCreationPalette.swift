import AppKit
import KanameConnectivity
import KanameDesktop
import KanamePrototypeUI
import SwiftUI
import KanameDesignSystem

private enum ProjectCreationSource: String, CaseIterable, Identifiable {
    case local
    case github
    case gitURL
    case folderless

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local folder"
        case .github: "GitHub repository"
        case .gitURL: "Git URL"
        case .folderless: "Project without a folder"
        }
    }

    var detail: String {
        switch self {
        case .local: "Choose an existing folder on this Mac"
        case .github: "Clone GitHub owner/repository"
        case .gitURL: "Clone from an HTTPS or SSH remote"
        case .folderless: "Keep planning, research, or personal work in Kaname"
        }
    }

    var symbol: String {
        switch self {
        case .local: "folder.badge.plus"
        case .github: "point.3.connected.trianglepath.dotted"
        case .gitURL: "link"
        case .folderless: "square.dashed"
        }
    }
}

@MainActor
private final class DesktopProjectIntakeViewModel: ObservableObject {
    @Published var inspection: DesktopProjectIntakeSnapshot?
    @Published var errorMessage: String?
    @Published var isWorking = false
    private let service = DesktopProjectIntakeService()
    private var task: Task<Void, Never>?

    func inspect(path: String) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        task = Task {
            do {
                inspection = try await service.inspectLocalDirectory(path: path)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func clone(reference: DesktopRemoteProjectReference, parentDirectory: String) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        task = Task {
            do {
                inspection = try await service.cloneRemote(
                    reference: reference,
                    parentDirectory: parentDirectory
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isWorking = false
    }

    func reset() {
        cancel()
        inspection = nil
        errorMessage = nil
    }
}

@MainActor
private final class DesktopProjectFolderBrowserViewModel: ObservableObject {
    @Published var path = DesktopProjectFolderBrowser.defaultPath()
    @Published var snapshot: DesktopProjectFolderBrowserSnapshot?
    @Published var errorMessage: String?
    @Published var isWorking = false

    private let service = DesktopProjectFolderBrowser()
    private var task: Task<Void, Never>?

    var existingDirectoryPath: String? { snapshot?.existingDirectoryPath }

    func browse() {
        browse(path: path)
    }

    func browse(path requestedPath: String) {
        task?.cancel()
        path = requestedPath
        snapshot = nil
        errorMessage = nil
        isWorking = true
        task = Task {
            do {
                let result = try await service.browse(path: requestedPath)
                try Task.checkCancellation()
                snapshot = result
                path = result.displayPath
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            if !Task.isCancelled { isWorking = false }
        }
    }

    func prepare(path: String) {
        task?.cancel()
        self.path = path
        snapshot = nil
        errorMessage = nil
        isWorking = false
    }

    func reset() {
        prepare(path: DesktopProjectFolderBrowser.defaultPath())
    }

    func cancel() {
        task?.cancel()
        task = nil
        isWorking = false
    }
}

struct DesktopProjectCreationPalette: View {
    @ObservedObject var model: DesktopAppModel
    let dismiss: () -> Void
    let created: (String) -> Void

    @StateObject private var intake = DesktopProjectIntakeViewModel()
    @StateObject private var folderBrowser = DesktopProjectFolderBrowserViewModel()
    @State private var query = ""
    @State private var selectedSource: ProjectCreationSource = .local
    @State private var activeSource: ProjectCreationSource?
    @State private var selectedFolderEntryPath: String?
    @State private var name = ""
    @State private var summary = ""
    @State private var kind: DesktopWorkKind = .coding
    @State private var instructionReferences = Set<String>()
    @State private var usesRepositoryRoot = true
    @State private var remoteValue = ""
    @State private var remoteParentPath = ""
    @State private var remoteReference: DesktopRemoteProjectReference?
    @State private var creationError: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var localFolderPathFocused: Bool
    @FocusState private var nameFocused: Bool

    private var visibleSources: [ProjectCreationSource] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return ProjectCreationSource.allCases }
        return ProjectCreationSource.allCases.filter {
            $0.title.lowercased().contains(term) || $0.detail.lowercased().contains(term)
        }
    }

    private var selectedPath: String? {
        guard let inspection = intake.inspection else { return nil }
        if usesRepositoryRoot, let repository = inspection.repository { return repository.root }
        return inspection.canonicalSelectedPath
    }

    private var availableInstructionReferences: [String] {
        guard let inspection = intake.inspection else { return [] }
        return usesRepositoryRoot
            ? inspection.repositoryInstructionReferences
            : inspection.selectedInstructionReferences
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let inspection = intake.inspection {
                    localReview(inspection)
                } else if let activeSource {
                    switch activeSource {
                    case .github, .gitURL: remoteEntry(activeSource)
                    case .folderless: folderlessEntry
                    case .local: localFolderBrowserEntry
                    }
                } else {
                    sourceList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(maxWidth: 700, minHeight: 470, maxHeight: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(KanameColor.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 34, y: 16)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .onDisappear {
            intake.cancel()
            folderBrowser.cancel()
        }
        .onChange(of: intake.inspection) { inspection in
            guard let inspection else { return }
            name = inspection.suggestedName
            instructionReferences = Set(inspection.instructionReferences)
            usesRepositoryRoot = inspection.isRepositorySubfolder
            creationError = nil
            DispatchQueue.main.async { nameFocused = true }
        }
        .onChange(of: usesRepositoryRoot) { _ in
            instructionReferences = Set(availableInstructionReferences)
        }
        .onMoveCommand { direction in
            if activeSource == nil, intake.inspection == nil {
                moveSelection(direction)
            } else if activeSource == .local, intake.inspection == nil, !localFolderPathFocused {
                moveFolderSelection(direction)
            }
        }
        .background {
            if activeSource == nil, intake.inspection == nil {
                DesktopPaletteKeyMonitor { direction in
                    guard activeSource == nil, intake.inspection == nil else { return }
                    switch direction {
                    case .previous: moveSelection(.up)
                    case .next: moveSelection(.down)
                    }
                }
                .frame(width: 0, height: 0)
            }
        }
        .background {
            if activeSource == .local, intake.inspection == nil {
                DesktopProjectFolderKeyMonitor(
                    isPathFocused: localFolderPathFocused,
                    move: moveFolderSelection,
                    activate: openSelectedFolder,
                    parent: browseParentFolder
                )
                .frame(width: 0, height: 0)
            }
        }
        .onExitCommand(perform: goBackOrDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add project")
    }

    private var header: some View {
        HStack(spacing: 12) {
            if activeSource != nil || intake.inspection != nil {
                Button("Back", systemImage: "chevron.left", action: goBack)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Back")
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(KanameColor.accent)
            }

            if activeSource == nil, intake.inspection == nil {
                TextField("Search project sources", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { choose(selectedSource) }
                    .accessibilityLabel("Search project sources")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(intake.inspection == nil ? (activeSource?.title ?? "Add project") : "Review project")
                        .font(.headline)
                    Text(intake.inspection == nil ? "Choose where Kaname should create the local checkout" : "Confirm the exact context Kaname will record")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if intake.isWorking { ProgressView().controlSize(.small) }
            Button("Close", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Close (Escape)")
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
    }

    private var sourceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text("SOURCES")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                ForEach(visibleSources) { source in
                    sourceRow(source)
                }
                if visibleSources.isEmpty {
                    Text("No project sources match “\(query)”.")
                        .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(40)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .onChange(of: visibleSources.map(\.id)) { _ in
            if !visibleSources.contains(selectedSource) {
                selectedSource = visibleSources.first ?? .local
            }
        }
    }

    private func sourceRow(_ source: ProjectCreationSource) -> some View {
        let selected = source == selectedSource
        return Button(action: { choose(source) }) {
            Grid(alignment: .leading, horizontalSpacing: 7, verticalSpacing: 3) {
                GridRow {
                    Image(systemName: source.symbol)
                    Text(source.title).fontWeight(.medium)
                }
                GridRow {
                    Color.clear.frame(width: 16, height: 1)
                    Text(source.detail).font(.caption).opacity(0.78)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if source == .github {
                    Text("Uses Git credentials")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((selected ? KanameColor.canvas : KanameColor.accent).opacity(0.12), in: Capsule())
                }
            }
            .foregroundStyle(selected ? KanameColor.canvas : KanameColor.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(selected ? KanameColor.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering in if hovering { selectedSource = source } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(source.title), \(source.detail)")
        .accessibilityHint("Select this project source")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func localReview(_ inspection: DesktopProjectIntakeSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                projectDetailsFields

                intakeCard(inspection)

                if !availableInstructionReferences.isEmpty {
                    GroupBox("Detected instructions") {
                        VStack(alignment: .leading, spacing: 8) {
                        ForEach(availableInstructionReferences, id: \.self) { reference in
                            Toggle(reference, isOn: membership(reference, in: $instructionReferences))
                        }
                        Text("Only selected references become project context. Their contents are not read while adding the project.")
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                boundaryNote("Creating records this local context only. It does not start a provider, modify the folder, create a worktree, or grant write access. Knowledge and skills remain deliberate choices on the project overview.")
                errorView
            }
            .padding(20)
        }
    }

    private var localFolderBrowserEntry: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Enter path (e.g. ~/Projects/my-app)", text: $folderBrowser.path)
                    .textFieldStyle(.roundedBorder)
                    .focused($localFolderPathFocused)
                    .onSubmit { browseLocalFolderPath() }
                    .accessibilityLabel("Local folder path")
                Button("Add", systemImage: "arrow.right", action: inspectLocalFolder)
                    .buttonStyle(.borderedProminent)
                    .disabled(folderBrowser.existingDirectoryPath == nil || folderBrowser.isWorking || intake.isWorking)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Review this folder before adding the project")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if folderBrowser.isWorking {
                ProgressView("Loading directories…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)
            }

            if let message = folderBrowser.errorMessage ?? intake.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(KanameColor.danger)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if let snapshot = folderBrowser.snapshot, !snapshot.entries.isEmpty {
                        ForEach(snapshot.entries) { entry in
                            localFolderRow(entry)
                        }
                    } else if !folderBrowser.isWorking && folderBrowser.errorMessage == nil {
                        Text("No directories in this folder.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(28)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: folderBrowser.snapshot?.entries.map(\.path) ?? []) { _, paths in
                if let selectedFolderEntryPath, paths.contains(selectedFolderEntryPath) {
                    return
                } else {
                    selectedFolderEntryPath = paths.first
                }
            }

            Text("Choose an existing folder to review. Kaname will not modify it while adding the project.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
        .onAppear {
            if folderBrowser.snapshot == nil && !folderBrowser.isWorking {
                folderBrowser.browse()
            }
            DispatchQueue.main.async { localFolderPathFocused = true }
        }
    }

    private func localFolderRow(_ entry: DesktopProjectFolderEntry) -> some View {
        let selected = entry.path == selectedFolderEntryPath
        return Button(action: { openFolder(entry) }) {
            HStack(spacing: 10) {
                Image(systemName: entry.isParent ? "arrow.turn.up.left" : "folder")
                    .frame(width: 18)
                Text(entry.name)
                    .fontWeight(entry.isParent ? .regular : .medium)
                Spacer()
                if entry.isParent {
                    Text("Parent")
                        .font(.caption2)
                        .opacity(0.72)
                }
            }
            .foregroundStyle(selected ? KanameColor.canvas : KanameColor.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                selected ? KanameColor.accent : KanameColor.surface.opacity(0.42),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedFolderEntryPath = entry.path }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isParent ? "Parent folder" : "\(entry.name) folder")
        .accessibilityHint(entry.isParent ? "Go up one folder" : "Open this folder")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func intakeCard(_ inspection: DesktopProjectIntakeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WORKSPACE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            LabeledContent("Selected folder", value: inspection.canonicalSelectedPath)
            if let repository = inspection.repository {
                LabeledContent("Git repository", value: repository.root)
                LabeledContent("Branch", value: repository.branch)
                LabeledContent("Status", value: repository.isClean ? "Clean" : "\(repository.changedPaths.count) changed")
                if inspection.isRepositorySubfolder {
                    Picker("Project scope", selection: $usesRepositoryRoot) {
                        Text("Repository root").tag(true)
                        Text("Selected subfolder").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Text(usesRepositoryRoot
                        ? "Kaname will use the repository root so Git and repository instructions share one boundary."
                        : "Kaname will keep the selected subfolder as the project boundary.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Git", value: "Not a repository")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func remoteEntry(_ source: ProjectCreationSource) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(source == .github ? "GITHUB REPOSITORY" : "GIT REMOTE")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    TextField(source == .github ? "owner/repository" : "https://… or git@…", text: $remoteValue)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: remoteValue) { _ in validateRemote() }
                    if let reference = remoteReference {
                        Label(reference.displayName, systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(KanameColor.success)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("LOCAL DESTINATION")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        Text(remoteParentPath.isEmpty ? "Choose a parent folder" : remoteParentPath)
                            .foregroundStyle(remoteParentPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseRemoteParent)
                    }
                    .padding(10)
                    .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
                    if let reference = remoteReference, !remoteParentPath.isEmpty {
                        Text("Will clone to \(URL(fileURLWithPath: remoteParentPath).appending(path: reference.suggestedName).path)")
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                boundaryNote("Clone is the only repository mutation in this flow and runs only after you choose Clone & review. Git or gh keeps responsibility for credentials.")
                errorView

            }
            .padding(20)
        }
    }

    private var folderlessEntry: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                projectDetailsFields
                boundaryNote("This project has no filesystem access. A folder can be added later from the project overview.")
                errorView
            }
            .padding(20)
        }
        .onAppear { DispatchQueue.main.async { nameFocused = true } }
    }

    private var projectDetailsFields: some View {
        GroupBox("Project") {
            Form {
                TextField("Project name", text: $name).focused($nameFocused)
                TextField("Purpose (optional)", text: $summary, axis: .vertical).lineLimit(2...4)
                Picker("Default conversation kind", selection: $kind) {
                    ForEach(DesktopWorkKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label(intake.inspection == nil ? "Explicit source selection" : "Review before saving", systemImage: "lock.shield")
                .foregroundStyle(KanameColor.success)
            Spacer()
            if intake.inspection != nil {
                Button("Change folder", action: showLocalFolderBrowser)
                    .buttonStyle(.plain)
                Button("Add project", action: createInspectedProject)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || intake.isWorking)
                    .keyboardShortcut(.defaultAction)
            } else if activeSource == .folderless {
                Button("Create project", action: createFolderless)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            } else if activeSource == .github || activeSource == .gitURL {
                Button("Clone & review", action: cloneRemote)
                    .buttonStyle(.borderedProminent)
                    .disabled(remoteReference == nil || remoteParentPath.isEmpty || intake.isWorking)
                    .keyboardShortcut(.defaultAction)
            } else if activeSource == .local {
                Text("↑↓ Navigate   ↩ Open   ⌫ Parent   esc Close")
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Open in Finder", action: openLocalFolderInFinder)
                    .buttonStyle(.plain)
            } else if activeSource == nil {
                Text("↑↓ Navigate   ↩ Select   esc Close").foregroundStyle(.tertiary)
            } else {
                Text("esc Back   × Close").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .frame(minHeight: 46)
    }

    @ViewBuilder
    private var errorView: some View {
        if let message = intake.errorMessage ?? creationError {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(KanameColor.danger)
                .textSelection(.enabled)
        }
    }

    private func boundaryNote(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    }

    private func choose(_ source: ProjectCreationSource) {
        selectedSource = source
        creationError = nil
        switch source {
        case .local:
            showLocalFolderBrowser()
        case .github, .gitURL:
            activeSource = source
        case .folderless:
            activeSource = source
            kind = .planning
        }
    }

    private func showLocalFolderBrowser() {
        intake.reset()
        folderBrowser.reset()
        selectedFolderEntryPath = nil
        activeSource = .local
        creationError = nil
        folderBrowser.browse()
        DispatchQueue.main.async { localFolderPathFocused = true }
    }

    private func browseLocalFolderPath() {
        selectedFolderEntryPath = nil
        folderBrowser.browse()
    }

    private func inspectLocalFolder() {
        guard let path = folderBrowser.existingDirectoryPath else { return }
        intake.inspect(path: path)
    }

    private func openFolder(_ entry: DesktopProjectFolderEntry) {
        selectedFolderEntryPath = entry.path
        folderBrowser.browse(path: entry.path)
        DispatchQueue.main.async { localFolderPathFocused = false }
    }

    private func browseParentFolder() {
        guard let parent = folderBrowser.snapshot?.parentDirectoryPath else { return }
        folderBrowser.browse(path: parent)
        selectedFolderEntryPath = nil
    }

    private func openSelectedFolder() {
        guard let selectedFolderEntryPath,
              let entry = folderBrowser.snapshot?.entries.first(where: { $0.path == selectedFolderEntryPath }) else {
            return
        }
        openFolder(entry)
    }

    private func openLocalFolderInFinder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Review project"
        if let existingPath = folderBrowser.existingDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: existingPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        folderBrowser.prepare(path: path)
        activeSource = .local
        intake.inspect(path: path)
    }

    private func chooseRemoteParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose destination"
        if panel.runModal() == .OK { remoteParentPath = panel.url?.standardizedFileURL.path ?? remoteParentPath }
    }

    private func validateRemote() {
        do {
            remoteReference = try DesktopProjectIntakeService.parseRemoteReference(remoteValue)
            intake.errorMessage = nil
            creationError = nil
        } catch {
            remoteReference = nil
            creationError = remoteValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : error.localizedDescription
        }
    }

    private func cloneRemote() {
        guard let remoteReference else { return }
        intake.clone(reference: remoteReference, parentDirectory: remoteParentPath)
    }

    private func createInspectedProject() {
        guard let selectedPath else { return }
        let context = DesktopProjectContext(
            instructionReferences: Array(instructionReferences).sorted(),
            defaultKind: kind
        )
        if let id = model.createProject(name: name, path: selectedPath, summary: summary, context: context) {
            created(id)
        } else {
            creationError = "A project already uses this folder, or the project details are not valid."
        }
    }

    private func createFolderless() {
        let context = DesktopProjectContext(defaultKind: kind)
        if let id = model.createProject(name: name, path: nil, summary: summary, context: context) {
            created(id)
        } else {
            creationError = "Review the project name before creating it."
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

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !visibleSources.isEmpty,
              let index = visibleSources.firstIndex(of: selectedSource) else { return }
        switch direction {
        case .up: selectedSource = visibleSources[max(0, index - 1)]
        case .down: selectedSource = visibleSources[min(visibleSources.count - 1, index + 1)]
        default: break
        }
    }

    private func moveFolderSelection(_ direction: MoveCommandDirection) {
        guard let entries = folderBrowser.snapshot?.entries, !entries.isEmpty else { return }
        let currentIndex = entries.firstIndex { $0.path == selectedFolderEntryPath } ?? 0
        switch direction {
        case .up:
            selectedFolderEntryPath = entries[max(0, currentIndex - 1)].path
        case .down:
            selectedFolderEntryPath = entries[min(entries.count - 1, currentIndex + 1)].path
        default:
            break
        }
    }

    private func goBackOrDismiss() {
        if activeSource == .local, intake.inspection == nil {
            close()
        } else if activeSource != nil || intake.inspection != nil {
            goBack()
        } else {
            close()
        }
    }

    private func goBack() {
        if activeSource == .local, intake.inspection != nil {
            showLocalFolderBrowser()
            return
        }
        intake.reset()
        folderBrowser.cancel()
        activeSource = nil
        creationError = nil
        DispatchQueue.main.async { searchFocused = true }
    }

    private func close() {
        intake.cancel()
        folderBrowser.cancel()
        dismiss()
    }
}

#if os(macOS)
private struct DesktopProjectFolderKeyMonitor: NSViewRepresentable {
    let isPathFocused: Bool
    let move: (MoveCommandDirection) -> Void
    let activate: () -> Void
    let parent: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPathFocused: isPathFocused,
            move: move,
            activate: activate,
            parent: parent
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPathFocused = isPathFocused
        context.coordinator.move = move
        context.coordinator.activate = activate
        context.coordinator.parent = parent
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var isPathFocused: Bool
        var move: (MoveCommandDirection) -> Void
        var activate: () -> Void
        var parent: () -> Void
        private var monitor: Any?

        init(
            isPathFocused: Bool,
            move: @escaping (MoveCommandDirection) -> Void,
            activate: @escaping () -> Void,
            parent: @escaping () -> Void
        ) {
            self.isPathFocused = isPathFocused
            self.move = move
            self.activate = activate
            self.parent = parent
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, !self.isPathFocused else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard modifiers.isEmpty else { return event }
                switch event.keyCode {
                case 125:
                    self.move(.down)
                    return nil
                case 126:
                    self.move(.up)
                    return nil
                case 36, 76:
                    self.activate()
                    return nil
                case 51:
                    self.parent()
                    return nil
                default:
                    return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
