import AppKit
import KanameConnectivity
import KanameDesktop
import KanamePrototypeUI
import SwiftUI

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
}

struct DesktopProjectCreationPalette: View {
    @ObservedObject var model: DesktopAppModel
    let dismiss: () -> Void
    let created: (String) -> Void

    @StateObject private var intake = DesktopProjectIntakeViewModel()
    @State private var query = ""
    @State private var selectedSource: ProjectCreationSource = .local
    @State private var activeSource: ProjectCreationSource?
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
                    case .local: localInspectionState
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
                .strokeBorder(Nord.polarNight3, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 34, y: 16)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .onDisappear { intake.cancel() }
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
            guard activeSource == nil, intake.inspection == nil else { return }
            moveSelection(direction)
        }
        .background {
            DesktopPaletteKeyMonitor { direction in
                guard activeSource == nil, intake.inspection == nil else { return }
                switch direction {
                case .previous: moveSelection(.up)
                case .next: moveSelection(.down)
                }
            }
            .frame(width: 0, height: 0)
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
                Image(systemName: "magnifyingglass").foregroundStyle(Nord.frost1)
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
                        .background((selected ? Nord.polarNight0 : Nord.frost1).opacity(0.12), in: Capsule())
                }
            }
            .foregroundStyle(selected ? Nord.polarNight0 : Nord.frost1)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(selected ? Nord.frost1 : Color.clear, in: RoundedRectangle(cornerRadius: 10))
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

    private var localInspectionState: some View {
        VStack(spacing: 14) {
            if intake.isWorking {
                ProgressView("Inspecting the selected folder…")
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(Nord.auroraYellow)
                Text(intake.errorMessage ?? "The selected folder could not be inspected.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
                Button("Choose another folder", action: chooseLocalFolder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 12))
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
                            .font(.caption).foregroundStyle(Nord.auroraGreen)
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
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 10))
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
                .foregroundStyle(Nord.auroraGreen)
            Spacer()
            if intake.inspection != nil {
                Button("Change folder", action: chooseLocalFolder)
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
                .foregroundStyle(Nord.auroraRed)
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
        .background(Nord.polarNight1.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    }

    private func choose(_ source: ProjectCreationSource) {
        selectedSource = source
        creationError = nil
        switch source {
        case .local:
            chooseLocalFolder()
        case .github, .gitURL:
            activeSource = source
        case .folderless:
            activeSource = source
            kind = .planning
        }
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Review project"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
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

    private func goBackOrDismiss() {
        if activeSource != nil || intake.inspection != nil { goBack() }
        else { close() }
    }

    private func goBack() {
        intake.cancel()
        intake.inspection = nil
        intake.errorMessage = nil
        activeSource = nil
        creationError = nil
        DispatchQueue.main.async { searchFocused = true }
    }

    private func close() {
        intake.cancel()
        dismiss()
    }
}
