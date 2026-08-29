import CryptoKit
import Foundation

/// Filesystem skill discovery and bounded body loading for coding prompts.
public enum SkillRegistryLoader {
    public static let maximumRegistryEntries = 100
    public static let maximumFrontmatterScanBytes = 8_192
    public static let maximumSkillBodyBytes = 12_288
    public static let maximumTotalSkillContextBytes = 24_576

    public static func defaultSearchRoots(workspaceRoot: URL? = nil) -> [URL] {
        var roots = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/skills"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agents/skills"),
        ]
        if let workspaceRoot {
            roots.append(workspaceRoot.appending(path: ".agents/skills"))
        }
        return roots
    }

    public static func loadRegistry(workspaceRoot: URL? = nil) -> [SkillRegistryEntry] {
        loadRegistry(searchRoots: defaultSearchRoots(workspaceRoot: workspaceRoot))
    }

    public static func loadRegistry(searchRoots: [URL]) -> [SkillRegistryEntry] {
        var entries: [SkillRegistryEntry] = []
        for root in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
                guard entries.count < maximumRegistryEntries,
                      let text = boundedText(at: url, maximumBytes: maximumFrontmatterScanBytes)
                else { continue }
                let name = frontmatterValue("name", in: text) ?? url.deletingLastPathComponent().lastPathComponent
                let description = frontmatterValue("description", in: text) ?? "No compact description available."
                entries.append(SkillRegistryEntry(name: name, description: description, path: url.path))
            }
        }
        return Dictionary(grouping: entries, by: \.name)
            .compactMap(\.value.first)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolves catalog identifiers and display names to loaded skill excerpts for prompt injection.
    public static func loadContextSources(
        identifiers: [String],
        catalogNamesByID: [String: String],
        workspaceRoot: URL? = nil,
        searchRoots: [URL]? = nil
    ) -> [CodingContextSource] {
        let registry = searchRoots.map(loadRegistry(searchRoots:))
            ?? loadRegistry(workspaceRoot: workspaceRoot)
        guard !identifiers.isEmpty, !registry.isEmpty else { return [] }

        var sources: [CodingContextSource] = []
        var consumedBytes = 0
        for identifier in identifiers {
            guard consumedBytes < maximumTotalSkillContextBytes else { break }
            guard let entry = resolveEntry(
                identifier: identifier,
                catalogName: catalogNamesByID[identifier],
                in: registry
            ) else { continue }
            guard let body = boundedText(
                at: URL(fileURLWithPath: entry.path),
                maximumBytes: min(maximumSkillBodyBytes, maximumTotalSkillContextBytes - consumedBytes)
            ) else { continue }
            let excerpt = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !excerpt.isEmpty else { continue }
            let source = CodingContextSource(
                kind: .skill,
                title: entry.name,
                path: entry.path,
                excerpt: excerpt
            )
            sources.append(source)
            consumedBytes += excerpt.utf8.count
        }
        return sources
    }

    public static func resolveEntry(
        identifier: String,
        catalogName: String?,
        in registry: [SkillRegistryEntry]
    ) -> SkillRegistryEntry? {
        if let exact = registry.first(where: { $0.path == identifier || $0.name == identifier }) {
            return exact
        }
        let normalizedID = normalized(identifier)
        if let idMatch = registry.first(where: { normalized($0.name) == normalizedID }) {
            return idMatch
        }
        if let catalogName,
           let catalogMatch = registry.first(where: { normalized($0.name) == normalized(catalogName) }) {
            return catalogMatch
        }
        let slug = normalizedID.replacingOccurrences(of: "skill-", with: "")
        return registry.first {
            normalized($0.name).contains(slug) || normalized($0.path).contains(slug)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func boundedText(at url: URL, maximumBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes), !data.isEmpty else { return nil }
        var result = String(decoding: data, as: UTF8.self)
        while result.utf8.count > maximumBytes { result.removeLast() }
        return result
    }

    private static func frontmatterValue(_ key: String, in text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        for line in text.split(separator: "\n").dropFirst().prefix(while: { $0 != "---" }) {
            let prefix = "\(key):"
            guard line.hasPrefix(prefix) else { continue }
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}
