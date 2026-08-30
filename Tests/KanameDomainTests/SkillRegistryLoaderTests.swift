import Foundation
import Testing
@testable import KanameConnectivity

struct SkillRegistryLoaderTests {
    private let exactResolutionRegistry = [
        SkillRegistryEntry(
            name: "mori-review-similarity",
            description: "Structural review",
            path: "/skills/mori-review-similarity/SKILL.md"
        ),
        SkillRegistryEntry(
            name: "home-audit",
            description: "Audit a home directory",
            path: "/Users/example/HOME/skills/home-audit/SKILL.md"
        ),
    ]

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
            registryNames: ["large-skill"],
            catalogRegistryNamesByID: [:],
            searchRoots: [root]
        )
        #expect(sources.count == 1)
        #expect(sources[0].kind == .skill)
        #expect(sources[0].excerpt.utf8.count <= SkillRegistryLoader.maximumTotalSkillContextBytes)
    }

    @Test
    func dollarHomeDoesNotResolve() {
        let sources = SkillRegistryLoader.loadContextSources(
            registryNames: ["HOME"],
            catalogRegistryNamesByID: [:],
            registry: exactResolutionRegistry
        )

        #expect(sources.isEmpty)
    }

    @Test
    func catalogAndLexicalOriginsRemainDistinctEndToEnd() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-exact-skill-origins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, heading) in [
            ("mori-review-similarity", "Bound registry skill"),
            ("skill-mori-review", "Colliding registry skill"),
            ("skill-custom", "Custom registry skill"),
            ("demo-skill", "Display and path fixture"),
        ] {
            let skillDirectory = root.appending(path: name)
            try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try """
            ---
            name: \(name)
            description: Exact identity fixture.
            ---

            # \(heading)
            """.write(to: skillDirectory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        let registry = SkillRegistryLoader.loadRegistry(searchRoots: [root])

        let boundCatalogSources = SkillRegistryLoader.loadContextSources(
            registryNames: [],
            catalogIDs: ["skill-mori-review"],
            catalogRegistryNamesByID: ["skill-mori-review": "mori-review-similarity"],
            registry: registry
        )
        let unboundCatalogSources = SkillRegistryLoader.loadContextSources(
            registryNames: [],
            catalogIDs: ["skill-custom"],
            catalogRegistryNamesByID: [:],
            registry: registry
        )
        let lexicalSources = SkillRegistryLoader.loadContextSources(
            registryNames: ["skill-custom"],
            catalogRegistryNamesByID: [:],
            registry: registry
        )
        let displayLabelSources = SkillRegistryLoader.loadContextSources(
            registryNames: [],
            catalogIDs: ["skill-demo"],
            catalogRegistryNamesByID: ["skill-demo": "Demo Skill"],
            registry: registry
        )
        let pathSources = SkillRegistryLoader.loadContextSources(
            registryNames: [root.appending(path: "demo-skill/SKILL.md").path],
            catalogRegistryNamesByID: [:],
            registry: registry
        )
        let boundSource = try #require(boundCatalogSources.first)

        #expect(boundCatalogSources.map(\.title) == ["mori-review-similarity"])
        #expect(boundSource.excerpt.contains("Bound registry skill"))
        #expect(!boundSource.excerpt.contains("Colliding registry skill"))
        #expect(unboundCatalogSources.isEmpty)
        #expect(lexicalSources.map(\.title) == ["skill-custom"])
        #expect(displayLabelSources.isEmpty)
        #expect(pathSources.isEmpty)
    }

    @Test
    func substringAndPathNeverMatch() {
        #expect(SkillRegistryLoader.resolveExactName("mori-review", in: exactResolutionRegistry) == nil)
        #expect(
            SkillRegistryLoader.resolveExactName(
                exactResolutionRegistry[0].path,
                in: exactResolutionRegistry
            ) == nil
        )
    }

    @Test
    func exactMatchResolves() {
        let expected = exactResolutionRegistry[0]

        #expect(SkillRegistryLoader.resolveExactName("mori-review-similarity", in: exactResolutionRegistry) == expected)
    }
}
