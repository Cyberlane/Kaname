import Foundation

/// The narrow Obsidian scopes that may be handed to the provider Bridge for a
/// run. Project selections further restrict the user's already granted vault
/// scopes; disabling project context produces no Bridge scopes.
public enum DesktopBridgeContext {
    public static func selectedVaultScopes(
        projectContext: DesktopProjectContext?,
        usesProjectContext: Bool,
        knowledgeSources: [DesktopKnowledgeSource],
        vaultScopes: [DesktopVaultScopeRecord]
    ) -> (read: [String], write: [String]) {
        guard usesProjectContext, let projectContext else { return ([], []) }
        let selectedIDs = Set(projectContext.knowledgeSourceIDs)
        let selectedPaths = knowledgeSources
            .filter { selectedIDs.contains($0.id) && $0.kind == .obsidian }
            .map(\.scope)
        func isInside(_ selectedPath: String, _ grantedPath: String) -> Bool {
            selectedPath == grantedPath || selectedPath.hasPrefix(grantedPath + "/")
        }
        let read = selectedPaths.filter { selectedPath in
            vaultScopes.contains { $0.canRead && isInside(selectedPath, $0.path) }
        }
        let write = selectedPaths.filter { selectedPath in
            vaultScopes.contains { $0.canWrite && isInside(selectedPath, $0.path) }
        }
        return (read, write)
    }
}
