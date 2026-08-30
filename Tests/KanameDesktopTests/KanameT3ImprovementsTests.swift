import Darwin
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
    func projectScriptsManifestEnforcesFileSizeBoundaryInDecodeAndLoad() throws {
        let base = try manifestData(scripts: [script(id: "test")])
        var atLimit = base
        atLimit.append(
            Data(
                repeating: 0x20,
                count: KanameProjectScriptsManifestLoader.maximumManifestBytes - base.count
            )
        )
        #expect(try KanameProjectScriptsManifestLoader.decode(atLimit).scripts.count == 1)

        var oversized = atLimit
        oversized.append(0x20)
        let expected = KanameProjectScriptsManifestError.manifestTooLarge(
            maximumBytes: KanameProjectScriptsManifestLoader.maximumManifestBytes
        )
        #expect(throws: expected) {
            try KanameProjectScriptsManifestLoader.decode(oversized)
        }

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appending(path: KanameProjectScriptsManifest.fileName)
        try atLimit.write(to: manifestURL)
        #expect(try KanameProjectScriptsManifestLoader.load(fromProjectRoot: root).scripts.count == 1)
        try oversized.write(to: manifestURL, options: .atomic)
        #expect(throws: expected) {
            try KanameProjectScriptsManifestLoader.load(fromProjectRoot: root)
        }
    }

    @Test
    func projectScriptsManifestEnforcesScriptCountBoundary() throws {
        let maximum = KanameProjectScriptsManifestLoader.maximumScriptCount
        let bounded = try manifestData(scripts: (0 ..< maximum).map { script(id: "script-\($0)") })
        #expect(try KanameProjectScriptsManifestLoader.decode(bounded).scripts.count == maximum)

        let oversized = try manifestData(scripts: (0 ... maximum).map { script(id: "script-\($0)") })
        #expect(
            throws: KanameProjectScriptsManifestError.tooManyScripts(maximumCount: maximum)
        ) {
            try KanameProjectScriptsManifestLoader.decode(oversized)
        }
    }

    @Test
    func projectScriptsManifestRefusesSymbolicAndHardLinks() throws {
        do {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appending(path: "source.json")
            try manifestData(scripts: [script(id: "symlink")]).write(to: target)
            let link = root.appending(path: KanameProjectScriptsManifest.fileName)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            expectManifestRefusal(at: root, error: .symbolicLink)
        }

        do {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appending(path: "source.json")
            let manifestURL = root.appending(path: KanameProjectScriptsManifest.fileName)
            try manifestData(scripts: [script(id: "hard-link")]).write(to: source)
            try FileManager.default.linkItem(at: source, to: manifestURL)
            expectManifestRefusal(at: root, error: .unreadableFile)
        }
    }

    @Test
    func projectScriptsManifestRefusesNonFileRootsAndNonRegularFiles() throws {
        let remoteRoot = URL(string: "https://example.com/project")!
        #expect(KanameProjectScriptsManifestLoader.detect(at: remoteRoot) == nil)
        #expect(throws: KanameProjectScriptsManifestError.unreadableFile) {
            try KanameProjectScriptsManifestLoader.load(fromProjectRoot: remoteRoot)
        }

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appending(path: KanameProjectScriptsManifest.fileName)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)
        expectManifestRefusal(at: root, error: .unreadableFile)

        try FileManager.default.removeItem(at: manifestURL)
        #expect(Darwin.mkfifo(manifestURL.path, S_IRUSR | S_IWUSR) == 0)
        expectManifestRefusal(at: root, error: .unreadableFile)
    }

    @Test
    func projectScriptsManifestRejectsFileMutationAfterRead() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appending(path: KanameProjectScriptsManifest.fileName)
        try manifestData(scripts: [script(id: "test")]).write(to: manifestURL)

        #expect(throws: KanameProjectScriptsManifestError.unreadableFile) {
            try KanameProjectScriptsManifestLoader.load(fromProjectRoot: root) { url in
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(" ".utf8))
            }
        }
    }

    @Test
    func projectScriptsManifestRejectsPathReplacementAfterRead() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appending(path: KanameProjectScriptsManifest.fileName)
        let replacement = root.appending(path: "replacement.json")
        let data = try manifestData(scripts: [script(id: "test")])
        try data.write(to: manifestURL)
        try data.write(to: replacement)

        #expect(throws: KanameProjectScriptsManifestError.unreadableFile) {
            try KanameProjectScriptsManifestLoader.load(fromProjectRoot: root) { url in
                try FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: replacement, to: url)
            }
        }
    }

    @Test
    func projectScriptsManifestRejectsNormalizedDuplicateIDs() throws {
        let data = try manifestData(scripts: [
            script(id: "test"),
            script(id: " test "),
        ])
        #expect(throws: KanameProjectScriptsManifestError.duplicateScriptID("test")) {
            try KanameProjectScriptsManifestLoader.decode(data)
        }
    }

    @Test
    func projectScriptsManifestUsesLocalPreviewURLPolicy() throws {
        let local = try manifestData(scripts: [
            script(id: "preview", previewURL: "http://localhost:5173/app"),
        ])
        #expect(try KanameProjectScriptsManifestLoader.decode(local).scripts.count == 1)

        let external = try manifestData(scripts: [
            script(id: "preview", previewURL: "https://evil.example"),
        ])
        #expect(throws: KanameProjectScriptsManifestError.invalidPreviewURL("preview")) {
            try KanameProjectScriptsManifestLoader.decode(external)
        }

        let fragmented = try manifestData(scripts: [
            script(id: "preview", previewURL: "http://localhost:5173/#results"),
        ])
        #expect(throws: KanameProjectScriptsManifestError.invalidPreviewURL("preview")) {
            try KanameProjectScriptsManifestLoader.decode(fragmented)
        }

        for previewURL in [
            "http://localhost:",
            "http://localhost:18446744073709551616",
            "http://[::1]:",
            "http://[::1]:18446744073709551616",
        ] {
            let malformedPort = try manifestData(scripts: [
                script(id: "preview", previewURL: previewURL),
            ])
            #expect(throws: KanameProjectScriptsManifestError.invalidPreviewURL("preview")) {
                try KanameProjectScriptsManifestLoader.decode(malformedPort)
            }
        }
    }

    @Test
    func projectScriptsManifestRejectsDisplayControlCharacters() throws {
        let ansiTitle = try manifestData(scripts: [
            script(id: "ansi-title", title: "\u{001B}[31mRun tests"),
        ])
        #expect(
            throws: KanameProjectScriptsManifestError.controlCharacters(
                scriptID: "ansi-title",
                field: "title"
            )
        ) {
            try KanameProjectScriptsManifestLoader.decode(ansiTitle)
        }

        let nulCommand = try manifestData(scripts: [
            script(id: "nul-command", command: "swift test\u{0000}"),
        ])
        #expect(
            throws: KanameProjectScriptsManifestError.controlCharacters(
                scriptID: "nul-command",
                field: "command"
            )
        ) {
            try KanameProjectScriptsManifestLoader.decode(nulCommand)
        }
    }

    @Test
    func projectScriptsManifestPreservesRawCommand() throws {
        let rawCommand = "  swift test --filter ExampleTests  "
        let decoded = try KanameProjectScriptsManifestLoader.decode(
            manifestData(scripts: [script(id: "test", command: rawCommand)])
        )
        #expect(decoded.scripts[0].command == rawCommand)

        let made = try KanameProjectScript.make(
            id: "test",
            title: "Run tests",
            command: rawCommand,
            kind: .tests
        )
        #expect(made.command == rawCommand)
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
        let allowed = [
            "http://127.0.0.1:5173",
            "https://localhost/path?theme=dark",
            "http://LOCALHOST:3000",
            "http://[::1]:8080",
        ]
        for value in allowed {
            #expect(CodingPreviewMCPGrant.isLocalPreviewURL(URL(string: value)!), "\(value) should be local")
        }

        let rejected = [
            "https://example.com",
            "http://localhost.example.com",
            "http://127.0.0.2",
            "ftp://localhost",
            "file:///tmp/index.html",
            "/relative-preview",
            "http://attacker@localhost:5173",
            "http://localhost:99999",
            "http://localhost:5173/#results",
            "http://localhost:",
            "http://localhost:18446744073709551616",
            "http://[::1]:",
            "http://[::1]:18446744073709551616",
        ]
        for value in rejected {
            #expect(!CodingPreviewMCPGrant.isLocalPreviewURL(URL(string: value)!), "\(value) should be rejected")
        }
    }

    @Test
    func portScannerParsesLocalhostListenLines() {
        let text = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        node    12345 justin   23u  IPv4 0x1      0t0  TCP 127.0.0.1:5173 (LISTEN)
        node    12345 justin   24u  IPv4 0x2      0t0  TCP *:3000 (LISTEN)
        """
        #expect(DesktopCodingTerminalPortScanner.parseListeningPorts(from: text) == [3000, 5173])
    }

    @Test
    func previewGrantMatcherRequiresExactApprovedTarget() {
        let target = CodingPreviewMCPGrant.exactTarget(threadID: "t1", worktreePath: "/tmp/wt")
        #expect(
            CodingPreviewMCPGrant.matchesApprovedGrant(
                title: CodingPreviewMCPGrant.approvalTitle,
                exactTarget: target,
                threadID: "t1",
                isApproved: true,
                expiresAtUnixMillis: nil,
                expectedThreadID: "t1",
                worktreePath: "/tmp/wt"
            )
        )
        #expect(
            !CodingPreviewMCPGrant.matchesApprovedGrant(
                title: CodingPreviewMCPGrant.approvalTitle,
                exactTarget: target,
                threadID: "t1",
                isApproved: false,
                expiresAtUnixMillis: nil,
                expectedThreadID: "t1",
                worktreePath: "/tmp/wt"
            )
        )
    }

    @Test
    func nativeDriversIncludeCursorAndGrokSessionArguments() throws {
        let workspace = URL(fileURLWithPath: "/tmp/workspace")
        let cursor = NativeConversationRequest(
            driver: .cursor,
            prompt: "Inspect only",
            workspace: workspace,
            model: "Use provider default",
            reasoningEffort: "high",
            runtimeMode: .approvalRequired,
            resumableSessionID: "cursor-session"
        )
        let cursorArgs = NativeProviderConversationSession.arguments(for: cursor)
        #expect(cursorArgs.contains("stream-json"))
        #expect(cursorArgs.contains("--mode"))
        #expect(cursorArgs.contains("plan"))
        #expect(cursorArgs.contains("--resume"))

        let grok = NativeConversationRequest(
            driver: .grok,
            prompt: "Inspect only",
            workspace: workspace,
            model: "Use provider default",
            reasoningEffort: "high",
            runtimeMode: .fullAccess,
            resumableSessionID: "grok-session"
        )
        let grokArgs = NativeProviderConversationSession.arguments(for: grok)
        #expect(grokArgs.contains("--single"))
        #expect(grokArgs.contains("streaming-messages-json"))
        #expect(grokArgs.contains("--always-approve"))
        #expect(NativeConversationDriver(providerName: "cursor-agent") == .cursor)
        #expect(NativeConversationDriver(providerName: "Grok") == .grok)
    }

    private func script(
        id: String,
        title: String = "Run tests",
        command: String = "swift test",
        previewURL: String? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "title": title,
            "command": command,
            "kind": "tests",
        ]
        if let previewURL { value["previewUrl"] = previewURL }
        return value
    }

    private func manifestData(scripts: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "scripts": scripts,
        ])
    }

    private func expectManifestRefusal(
        at root: URL,
        error: KanameProjectScriptsManifestError
    ) {
        #expect(KanameProjectScriptsManifestLoader.detect(at: root) == nil)
        #expect(throws: error) {
            try KanameProjectScriptsManifestLoader.load(fromProjectRoot: root)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kaname-manifest-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
