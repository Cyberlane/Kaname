import Foundation
import KanameConnectivity
import KanameDesktop

@MainActor
final class DesktopThreadChangesViewModel: ObservableObject {
    @Published private(set) var snapshot: GitWorktreeSnapshot?
    @Published private(set) var patch = ""
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published var selectedPath: String?
    @Published var searchText = ""

    private let service: DesktopGitControlService
    private var loadedWorktreePath: String?
    private var requestGeneration = 0

    init(environment: KanameDesktopEnvironment = .current) {
        service = DesktopGitControlService(managedRoot: environment.worktreeDirectory)
    }

    var filteredPaths: [String] {
        guard let paths = snapshot?.changedFiles else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? paths : paths.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    func load(worktree: DesktopWorktreeRecord, force: Bool = false) {
        guard force || loadedWorktreePath != worktree.worktreePath else { return }
        loadedWorktreePath = worktree.worktreePath
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        message = nil
        Task {
            do {
                let result = try await service.inspect(
                    worktree: URL(fileURLWithPath: worktree.worktreePath, isDirectory: true),
                    rootRepository: URL(fileURLWithPath: worktree.rootWorkspacePath, isDirectory: true)
                )
                let nextPath = selectedPath.flatMap { result.changedFiles.contains($0) ? $0 : nil }
                    ?? result.changedFiles.first
                let nextPatch: String
                if let nextPath {
                    nextPatch = try await service.diff(
                        worktree: URL(fileURLWithPath: worktree.worktreePath, isDirectory: true),
                        relativePath: nextPath
                    )
                } else {
                    nextPatch = ""
                }
                guard generation == requestGeneration else { return }
                snapshot = result
                selectedPath = nextPath
                patch = nextPatch
            } catch {
                guard generation == requestGeneration else { return }
                message = error.localizedDescription
                snapshot = nil
                patch = ""
            }
            isLoading = false
        }
    }

    func select(path: String, worktree: DesktopWorktreeRecord) {
        guard selectedPath != path || patch.isEmpty else { return }
        requestGeneration += 1
        let generation = requestGeneration
        selectedPath = path
        patch = ""
        isLoading = true
        message = nil
        Task {
            do {
                let result = try await service.diff(
                    worktree: URL(fileURLWithPath: worktree.worktreePath, isDirectory: true),
                    relativePath: path
                )
                guard generation == requestGeneration else { return }
                patch = result
            } catch {
                guard generation == requestGeneration else { return }
                message = error.localizedDescription
            }
            isLoading = false
        }
    }
}
