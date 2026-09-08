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

private struct DesktopGlobalSearchScheduledRequest: Sendable {
    let schedule: DesktopGlobalSearchSnapshotCoordinator.Schedule
    let query: DesktopGlobalSearchQuery
    let snapshot: DesktopAppSnapshot
}

private struct DesktopGlobalSearchScheduledOutput: Sendable {
    let corpus: DesktopGlobalSearchLocalCorpus
    let search: DesktopGlobalSearchOutput
}

struct DesktopGlobalSearchPalette: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snapshot: DesktopAppSnapshot
    let currentProjectID: String?
    let dismiss: () -> Void
    let open: (DesktopGlobalSearchResult) -> Void
    let perform: (DesktopCommandCenterAction) -> Void
    @State private var query = ""
    @State private var selection = DesktopGlobalSearchSelectionState()
    @State private var sections: [DesktopGlobalSearchSection] = []
    @State private var ftsRowCache = DesktopGlobalSearchFTS.IndexedRowCache()
    @State private var searchCoordinator = DesktopGlobalSearchSnapshotCoordinator()
    @State private var scheduledRequest: DesktopGlobalSearchScheduledRequest?
    @State private var isSearching = false
    @State private var searchStatusLine: String?
    @State private var selectedCommandIndex = 0
    @FocusState private var queryFocused: Bool

    init(
        snapshot: DesktopAppSnapshot,
        currentProjectID: String?,
        initialQuery: String = "",
        dismiss: @escaping () -> Void,
        open: @escaping (DesktopGlobalSearchResult) -> Void,
        perform: @escaping (DesktopCommandCenterAction) -> Void
    ) {
        self.snapshot = snapshot
        self.currentProjectID = currentProjectID
        self.dismiss = dismiss
        self.open = open
        self.perform = perform
        _query = State(initialValue: initialQuery)
    }

    private var resultCount: Int {
        sections.reduce(0) { $0 + $1.results.count }
    }

    private var commandQuery: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(">") else { return "" }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var showsCommands: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix(">")
    }

    private var commandActions: [DesktopCommandCenterAction] {
        let activeProjects = snapshot.projects
            .filter { $0.archivedAtUnixMillis == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let currentProject = activeProjects.first { $0.id == currentProjectID }
        var actions: [DesktopCommandCenterAction] = []
        if let currentProject {
            actions.append(.newConversation(projectID: currentProject.id, projectName: currentProject.name))
        }
        actions.append(.newConversation(projectID: nil, projectName: nil))
        if query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">") {
            actions.append(contentsOf: activeProjects
                .filter { $0.id != currentProjectID }
                .map { .newConversation(projectID: $0.id, projectName: $0.name) })
        }
        actions.append(.configureConversation(projectID: currentProject?.id, projectName: currentProject?.name))
        actions.append(.newProject)
        // Keep the command destination catalog in lockstep with the product
        // destination enum. The command center is the keyboard path to every
        // workspace, including the destinations that are intentionally quiet
        // in the sidebar and the Home/Threads/Settings entry points.
        actions.append(contentsOf: DesktopDestination.allCases.map { .open($0) })
        guard !commandQuery.isEmpty else { return actions }
        return actions.filter {
            $0.title.lowercased().contains(commandQuery)
                || $0.detail.lowercased().contains(commandQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(KanameColor.accent)
                TextField("Search Kaname or type > for actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($queryFocused)
                    .onSubmit { openSelection() }
                    .accessibilityLabel("Search Kaname")
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating local search results")
                }
                if !query.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Button("Close search", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Close search (Escape)")
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 58)

            Divider()

            Group {
                if showsCommands {
                    commandPrompt
                } else if sections.isEmpty && isSearching {
                    ProgressView("Searching the local snapshot…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sections.isEmpty {
                    EmptyPanel(
                        symbol: "magnifyingglass",
                        title: "No local results",
                        detail: "Try a title, project, account, status, or source name. Kaname will not contact a provider to broaden the search."
                    )
                    .padding(24)
                } else {
                    searchResults
                        .opacity(isSearching ? 0.62 : 1)
                        .allowsHitTesting(!isSearching)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let searchStatusLine {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(searchStatusLine)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(searchStatusLine)
            }

            Divider()
            HStack(spacing: 14) {
                Label("Local actions and snapshots", systemImage: "lock.shield")
                    .foregroundStyle(KanameColor.success)
                Text("No providers, accounts, credentials, or vaults are contacted")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("↑↓ Select   ↩ Open   esc Close")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 18)
            .frame(minHeight: 42)
        }
        .frame(maxWidth: 720, maxHeight: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(KanameColor.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.34), radius: 30, y: 14)
        .onAppear {
            scheduleSearch()
            DispatchQueue.main.async { queryFocused = true }
        }
        .onChange(of: query) { _ in
            selectedCommandIndex = 0
            scheduleSearch()
        }
        .onChange(of: DesktopGlobalSearchFTS.snapshotGeneration(from: snapshot)) { _ in
            scheduleSearch()
        }
        .onChange(of: snapshot.lastSavedAtUnixMillis) { _ in
            scheduleSearch()
        }
        .task(id: searchCoordinator.latestRequestGeneration) {
            await runScheduledSearch(scheduledRequest)
        }
        .onDisappear {
            searchCoordinator.cancel()
            scheduledRequest = nil
            isSearching = false
            searchStatusLine = nil
        }
        .onMoveCommand { direction in
            guard !isSearching else { return }
            switch direction {
            case .up: moveSelection(.previous)
            case .down: moveSelection(.next)
            default: break
            }
        }
        .background {
#if os(macOS)
            DesktopPaletteKeyMonitor { direction in
                guard !isSearching else { return }
                moveSelection(direction)
            }
            .frame(width: 0, height: 0)
#endif
        }
        .onExitCommand(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search Kaname")
    }

    private func scheduleSearch() {
        let schedule = searchCoordinator.schedule(snapshot: snapshot)
        if showsCommands {
            sections = []
            selection.reconcile(with: [])
            scheduledRequest = nil
            isSearching = false
            searchStatusLine = nil
            return
        }
        let searchQuery = DesktopGlobalSearchQuery(query)
        guard !searchQuery.isEmpty else {
            sections = []
            selection.reconcile(with: [])
            scheduledRequest = nil
            isSearching = false
            searchStatusLine = nil
            return
        }
        isSearching = true
        searchStatusLine = nil
        scheduledRequest = DesktopGlobalSearchScheduledRequest(
            schedule: schedule,
            query: searchQuery,
            snapshot: snapshot
        )
    }

    private func runScheduledSearch(_ request: DesktopGlobalSearchScheduledRequest?) async {
        guard let request else { return }
        do {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        guard !_Concurrency.Task<Never, Never>.isCancelled else { return }

        let rowCache = ftsRowCache
        let worker = _Concurrency.Task<DesktopGlobalSearchScheduledOutput?, Never>.detached(priority: .userInitiated) {
            guard !_Concurrency.Task<Never, Never>.isCancelled else { return nil }
            let ftsRows = await rowCache.rows(for: request.snapshot)
            guard !_Concurrency.Task<Never, Never>.isCancelled else { return nil }
            let corpus = request.schedule.cachedCorpus
                ?? DesktopGlobalSearchLocalIndex.corpus(
                    from: request.snapshot,
                    supplementalRows: ftsRows
                )
            guard !_Concurrency.Task<Never, Never>.isCancelled else { return nil }
            let indexPath = KanameDesktopEnvironment.current.desktopDirectory
                .appendingPathComponent("search-index.sqlite").path
            var search = DesktopGlobalSearch.searchOutput(
                query: request.query,
                in: corpus,
                ftsRows: ftsRows,
                persistentDatabasePath: indexPath
            )
            guard !_Concurrency.Task<Never, Never>.isCancelled else { return nil }
            // Live Obsidian hits across the readable vault scopes join the
            // Knowledge section, so Cmd-K reaches the notes too.
            let readableScopes = request.snapshot.operations.vaultScopes.filter(\.canRead).map(\.path)
            let rawQuery = request.query.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !readableScopes.isEmpty, rawQuery.count >= 3,
               let service = try? ObsidianVaultService(readableScopes: readableScopes, writableScopes: []) {
                var hits: [DesktopGlobalSearchResult] = []
                let capturedAt = Int64(Date().timeIntervalSince1970 * 1_000)
                for scope in readableScopes where hits.count < 8 {
                    guard !_Concurrency.Task<Never, Never>.isCancelled else { return nil }
                    guard let results = try? await service.search(query: rawQuery, scope: scope, limit: 4) else { continue }
                    for result in results where hits.count < 8 && !hits.contains(where: { $0.document.id == "vault-note:\(result.path)" }) {
                        hits.append(DesktopGlobalSearchResult(
                            document: DesktopGlobalSearchLocalIndex.vaultNoteDocument(path: result.path, context: result.context, capturedAtUnixMillis: capturedAt),
                            score: 50,
                            matchedFields: [.summary]
                        ))
                    }
                }
                if !hits.isEmpty {
                    var sections = search.sections
                    if let index = sections.firstIndex(where: { $0.domain == .knowledge }) {
                        sections[index] = DesktopGlobalSearchSection(domain: .knowledge, results: sections[index].results + hits)
                    } else {
                        sections.append(DesktopGlobalSearchSection(domain: .knowledge, results: hits))
                    }
                    search = DesktopGlobalSearchOutput(sections: sections, fullTextResult: search.fullTextResult)
                }
            }
            guard !_Concurrency.Task<Never, Never>.isCancelled else { return nil }
            return DesktopGlobalSearchScheduledOutput(corpus: corpus, search: search)
        }
        let output = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !_Concurrency.Task<Never, Never>.isCancelled,
              let output,
              scheduledRequest?.schedule.requestGeneration == request.schedule.requestGeneration,
              searchCoordinator.apply(corpus: output.corpus, for: request.schedule) else { return }
        sections = output.search.sections
        searchStatusLine = output.search.statusLine
        isSearching = false
        selection.reconcile(with: output.search.sections)
    }

    private var commandPrompt: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Suggested actions" : "Actions", systemImage: "command")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Type > to find every command")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)

                    if commandActions.isEmpty {
                        EmptyPanel(
                            symbol: "command",
                            title: "No matching actions",
                            detail: "Try a project, destination, or workflow name. Remove > to search saved content."
                        )
                        .frame(minHeight: 220)
                    } else {
                        ForEach(Array(commandActions.enumerated()), id: \.element.id) { index, action in
                            commandRow(action, isSelected: index == selectedCommandIndex)
                                .id(action.id)
                        }
                    }
                }
                .padding(14)
            }
            .onChange(of: selectedCommandIndex) { index in
                guard commandActions.indices.contains(index) else { return }
                if reduceMotion {
                    proxy.scrollTo(commandActions[index].id, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(commandActions[index].id, anchor: .center)
                    }
                }
            }
        }
        .accessibilityLabel("\(commandActions.count) Command Center actions")
    }

    private func commandRow(_ action: DesktopCommandCenterAction, isSelected: Bool) -> some View {
        Button { perform(action) } label: {
            CommandCenterSelectableLabel(
                symbol: action.symbol,
                title: action.title,
                detail: action.detail,
                provenance: nil,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var searchResults: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(section.title, systemImage: symbol(for: section.domain))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(section.results.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 6)

                            ForEach(section.results) { result in
                                resultRow(result)
                                    .id(result.selectionID)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .onChange(of: selection.selectedResultID) { selectedID in
                guard let selectedID else { return }
                if reduceMotion {
                    proxy.scrollTo(selectedID, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
        }
        .accessibilityLabel("\(resultCount) search results")
        .onChange(of: resultCount) { count in
            KanameAccessibilityAnnouncement.post("\(count) local search results")
        }
    }

    private func resultRow(_ result: DesktopGlobalSearchResult) -> some View {
        let isSelected = selection.selectedResultID == result.selectionID
        return Button {
            open(result)
        } label: {
            CommandCenterSelectableLabel(
                symbol: symbol(for: result.domain),
                title: result.document.title,
                detail: result.document.summary,
                provenance: provenanceText(result.provenance),
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .disabled(isSearching)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.domain.label), \(result.document.title), \(provenanceText(result.provenance))")
        .accessibilityHint("Open this result")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func openSelection() {
        guard !isSearching else { return }
        if showsCommands {
            guard commandActions.indices.contains(selectedCommandIndex) else { return }
            perform(commandActions[selectedCommandIndex])
            return
        }
        guard let result = selection.result(in: sections) ?? sections.first?.results.first else { return }
        open(result)
    }

    private func moveSelection(_ direction: DesktopGlobalSearchSelectionDirection) {
        guard showsCommands else {
            selection.move(direction, in: sections)
            return
        }
        guard !commandActions.isEmpty else {
            selectedCommandIndex = 0
            return
        }
        switch direction {
        case .previous:
            selectedCommandIndex = selectedCommandIndex == 0
                ? commandActions.count - 1
                : selectedCommandIndex - 1
        case .next:
            selectedCommandIndex = selectedCommandIndex + 1 == commandActions.count
                ? 0
                : selectedCommandIndex + 1
        }
    }

    private func provenanceText(_ provenance: DesktopGlobalSearchProvenance) -> String {
        [
            provenance.sourceLabel,
            provenance.projectLabel,
            provenance.accountLabel,
            provenance.scopeLabel,
        ]
        .compactMap { $0 }
        .reduce(into: [String]()) { labels, label in
            if !labels.contains(label) { labels.append(label) }
        }
        .joined(separator: " · ")
    }

    private func symbol(for domain: DesktopGlobalSearchDomain) -> String {
        switch domain {
        case .conversations: "bubble.left.and.bubble.right"
        case .projects: "folder"
        case .research: "text.magnifyingglass"
        case .knowledge: "diamond"
        case .email: "envelope"
        case .calendar: "calendar"
        case .automations: "clock.arrow.2.circlepath"
        case .github: "point.3.connected.trianglepath.dotted"
        case .skills: "hammer"
        case .approvals: "checkmark.shield"
        case .artifacts: "doc"
        }
    }
}

private struct CommandCenterSelectableLabel: View {
    let symbol: String
    let title: String
    let detail: String
    let provenance: String?
    let isSelected: Bool

    var body: some View {
        Label {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isSelected ? KanameColor.canvas : .primary)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(isSelected ? KanameColor.surface : .secondary)
                            .lineLimit(1)
                    }
                    if let provenance {
                        Text(provenance)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? KanameColor.raised : KanameColor.accent)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "return")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KanameColor.surface)
                }
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(isSelected ? KanameColor.canvas : KanameColor.accent)
                .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(isSelected ? KanameColor.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

#if os(macOS)
struct DesktopLocalKeyMonitor: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: handle)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var handle: (NSEvent) -> Bool
        private var monitor: Any?

        init(handle: @escaping (NSEvent) -> Bool) {
            self.handle = handle
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

struct DesktopPaletteKeyMonitor: View {
    let move: (DesktopGlobalSearchSelectionDirection) -> Void

    var body: some View {
        DesktopLocalKeyMonitor { event in
            let commandModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard commandModifiers.isEmpty else { return false }
            switch event.keyCode {
            case 125:
                move(.next)
                return true
            case 126:
                move(.previous)
                return true
            default:
                return false
            }
        }
    }
}
#endif
