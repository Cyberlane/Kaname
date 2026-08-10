import Foundation
import Testing
@testable import KanameConnectivity

struct ObsidianVaultServiceTests {
    @Test
    func inspectParsesNativeKnowledgeContextWithinExactScope() async throws {
        let fixture = try FixtureObsidian(note: "# Overview\nSee [[Decision Log|decisions]] and ![[diagram.png]].\nSource: https://example.com/research")
        defer { fixture.remove() }
        let service = try ObsidianVaultService(
            readableScopes: ["Projects/Coding ADE"],
            writableScopes: [],
            executable: fixture.executable.path
        )

        let result = try await service.inspect(path: "Projects/Coding ADE/Overview.md")

        #expect(result.content.contains("# Overview"))
        #expect(result.wikilinks == ["Decision Log"])
        #expect(result.attachments == ["diagram.png"])
        #expect(result.backlinks == ["Projects/Coding ADE/Research Index.md"])
        #expect(result.properties["status"] == "active")
        #expect(result.digest.count == 64)
    }

    @Test
    func searchAndDiffRemainBoundedToGrantedScope() async throws {
        let fixture = try FixtureObsidian(note: "# Old\nKeep\n")
        defer { fixture.remove() }
        let service = try ObsidianVaultService(
            readableScopes: ["Projects/Coding ADE"],
            writableScopes: ["Projects/Coding ADE"],
            executable: fixture.executable.path
        )

        let results = try await service.search(query: "authority", scope: "Projects/Coding ADE")
        let diff = try await service.proposedDiff(
            path: "Projects/Coding ADE/Overview.md",
            baseContent: "# Old\nKeep",
            proposedContent: "# New\nKeep"
        )

        #expect(results.map(\.path) == ["Projects/Coding ADE/Overview.md"])
        #expect(diff.summary == "1 removed · 1 added line")
        #expect(diff.unifiedDiff.contains("-# Old"))
        #expect(diff.unifiedDiff.contains("+# New"))
        await #expect(throws: ObsidianVaultError.outsideScope) {
            try await service.inspect(path: "Private/Secret.md")
        }
    }

    @Test
    func approvedWriteRechecksBaseAndReconcilesExactContent() async throws {
        let fixture = try FixtureObsidian(note: "# Original")
        defer { fixture.remove() }
        let service = try ObsidianVaultService(
            readableScopes: ["Projects/Coding ADE"],
            writableScopes: ["Projects/Coding ADE"],
            executable: fixture.executable.path
        )
        let original = try await service.inspect(path: "Projects/Coding ADE/Overview.md")
        let grant = ObsidianNoteMutationGrant(
            approvalID: "approval-1",
            targetPath: original.path,
            baseDigest: original.digest
        )

        let updated = try await service.write(path: original.path, content: "# Updated", grant: grant)

        #expect(updated.content == "# Updated")
        #expect(updated.digest != original.digest)

        await #expect(throws: ObsidianVaultError.conflict(currentDigest: updated.digest)) {
            try await service.write(path: original.path, content: "# Stale", grant: grant)
        }
    }
}

private struct FixtureObsidian {
    let directory: URL
    let executable: URL

    init(note: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "kaname-obsidian-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = directory.appending(path: "note.md")
        try Data(note.utf8).write(to: state)
        executable = directory.appending(path: "obsidian-fixture")
        let quotedState = state.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        case "$1" in
          read) cat '\(quotedState)' ;;
          backlinks) printf '%s' '[{"path":"Projects/Coding ADE/Research Index.md"}]' ;;
          properties) printf '%s' '{"status":"active","tags":["project"]}' ;;
          search:context) printf '%s' '[{"path":"Projects/Coding ADE/Overview.md","context":"authority boundary"}]' ;;
          eval) printf '%s' '# Updated' > '\(quotedState)'; printf '%s' 'true' ;;
          *) exit 2 ;;
        esac
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
