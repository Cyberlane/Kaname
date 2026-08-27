import Foundation
import Testing
@testable import KanameConnectivity
@testable import KanameDesktop

struct KanameT3ImprovementsTests {
    @Test
    func projectScriptsManifestDecodesQualityGateMapping() throws {
        let json = """
        {
          "schemaVersion": 1,
          "scripts": [
            {
              "id": "test",
              "title": "Run tests",
              "command": "swift test",
              "kind": "tests",
              "runOnWorktreeReady": true
            }
          ]
        }
        """.data(using: .utf8)!
        let manifest = try KanameProjectScriptsManifestLoader.decode(json)
        #expect(manifest.scripts.count == 1)
        #expect(manifest.scripts[0].kind == .tests)
        let gate = KanameProjectScriptsManifestLoader.qualityGate(
            from: manifest.scripts[0],
            threadID: "thread-1",
            worktreeID: "wt-1",
            summary: "ok",
            state: .completed,
            recordedAtUnixMillis: 1
        )
        #expect(gate.kind == .tests)
        #expect(gate.command == "swift test")
    }

    @Test
    func terminalServiceBoundsScrollbackAndBuildsAttachSource() async {
        let service = DesktopCodingTerminalService()
        var record = await service.ensureDefaultTerminal(
            threadID: "thread-1",
            cwd: "/tmp",
            nowUnixMillis: 1
        )
        let chunk = String(repeating: "line\n", count: 5_000)
        record = await service.appendOutput(text: chunk, record: record, nowUnixMillis: 2)
        #expect(record.scrollbackExcerpt.utf8.count <= DesktopCodingTerminalRecord.maximumExcerptBytes)
        let source = await service.attachContextSource(from: record)
        #expect(source?.kind == .terminal)
        #expect(source?.excerpt.contains("UNTRUSTED TERMINAL EXCERPT") == true)
    }

    @Test
    func previewMCPGrantStaysFailClosedWithoutApproval() {
        #expect(CodexMCPIsolation.allowsCuratedPreviewMCP(hasPreviewGrant: false) == false)
        #expect(CodexMCPIsolation.allowsCuratedPreviewMCP(hasPreviewGrant: true) == true)
        #expect(CodingPreviewMCPGrant.actionKind == "coding.preview_mcp_grant")
        #expect(!CodingPreviewMCPGrant.curatedToolAllowlist.isEmpty)
    }

    @Test
    func checkpointRefUsesKanameNamespace() {
        let ref = DesktopGitControlService.checkpointRef(
            threadID: "thread/1",
            turnID: "run-abc",
            bracket: "before"
        )
        #expect(ref.hasPrefix("refs/kaname/checkpoints/"))
        #expect(ref.contains("before"))
    }

    @Test
    func localPreviewURLAllowsLocalhostOnly() {
        #expect(CodingPreviewMCPGrant.isLocalPreviewURL(URL(string: "http://127.0.0.1:5173")!) == true)
        #expect(CodingPreviewMCPGrant.isLocalPreviewURL(URL(string: "https://example.com")!) == false)
    }
}
