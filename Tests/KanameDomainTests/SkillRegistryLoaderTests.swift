import Foundation
import Testing
@testable import KanameConnectivity

struct SkillRegistryLoaderTests {
    @Test
    func loadRegistryReadsSkillFrontmatterFromTemporaryTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-skill-registry-\(UUID().uuidString)")
        let skillDirectory = root.appending(path: "demo-skill")
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let skillFile = skillDirectory.appending(path: "SKILL.md")
        try """
        ---
        name: demo-skill
        description: Demonstrates bounded skill loading.
        ---

        # Demo

        Follow the host workflow only.
        """.write(to: skillFile, atomically: true, encoding: .utf8)

        let registry = SkillRegistryLoader.loadRegistry(searchRoots: [root])
        #expect(registry.count == 1)
        #expect(registry[0].name == "demo-skill")
        #expect(registry[0].description == "Demonstrates bounded skill loading.")
    }

    @Test
    func loadContextSourcesBoundsTotalBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-skill-bodies-\(UUID().uuidString)")
        let skillDirectory = root.appending(path: "large-skill")
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = String(repeating: "x", count: 30_000)
        try """
        ---
        name: large-skill
        description: Large body
        ---

        \(body)
        """.write(to: skillDirectory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let sources = SkillRegistryLoader.loadContextSources(
            identifiers: ["large-skill"],
            catalogNamesByID: [:],
            searchRoots: [root]
        )
        #expect(sources.count == 1)
        #expect(sources[0].kind == .skill)
        #expect(sources[0].excerpt.utf8.count <= SkillRegistryLoader.maximumTotalSkillContextBytes)
    }
}
