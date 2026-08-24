#if os(macOS)
import Foundation
import Testing
@testable import KanameLinkTunnelTool

@Suite(.serialized)
struct KanameLinkTunnelToolArgumentParserTests {
    private let parser = KanameLinkTunnelToolArgumentParser()

    @Test
    func enrollmentAndStatusAcceptNoAdditionalValues() throws {
        #expect(try parser.parse(["enroll-token"]) == .enrollToken)
        #expect(try parser.parse(["credential-status"]) == .credentialStatus)

        for arguments in [
            ["enroll-token", "--token", "forbidden"],
            ["enroll-token", "--token-file", "/forbidden"],
            ["enroll-token", "unexpected"],
            ["credential-status", "unexpected"],
        ] {
            #expect(throws: KanameLinkTunnelToolError.invalidArguments) {
                try parser.parse(arguments)
            }
        }
    }

    @Test
    func runParsesOnlyTheSixExactBoundedIdentityFlags() throws {
        let command = try parser.parse(validRunArguments())
        guard case let .run(paths) = command else {
            Issue.record("Expected a run command")
            return
        }

        #expect(paths.nodeExecutableURL.path == "/opt/kaname/runtime/node")
        #expect(paths.nodeExecutableSHA256 == String(repeating: "a", count: 64))
        #expect(paths.cloudflaredBinaryURL.path ==
            "/opt/kaname/cloudflared/2026.8.2/cloudflared")
        #expect(paths.installReceiptURL.path ==
            "/opt/kaname/cloudflared/2026.8.2/install-receipt.json")
        #expect(paths.supervisorScriptURL.path ==
            "/opt/kaname/tunnel/Scripts/kaname-link-cloudflared-supervisor.mjs")
        #expect(paths.runtimeManifestURL.path ==
            "/opt/kaname/tunnel/Infrastructure/KanameLinkTunnel/cloudflared-runtime.json")
    }

    @Test
    func runRejectsMissingDuplicateUnknownRelativeAndNoncanonicalValues() {
        var cases: [[String]] = []

        var missing = validRunArguments()
        missing.removeLast(2)
        cases.append(missing)

        var duplicate = validRunArguments()
        duplicate[11] = "--node"
        cases.append(duplicate)

        var unknown = validRunArguments()
        unknown[1] = "--unknown"
        cases.append(unknown)

        var relative = validRunArguments()
        relative[2] = "relative/node"
        cases.append(relative)

        var noncanonical = validRunArguments()
        noncanonical[2] = "/opt/kaname/../runtime/node"
        cases.append(noncanonical)

        var invalidDigest = validRunArguments()
        invalidDigest[4] = "not-a-digest"
        cases.append(invalidDigest)

        var oversized = validRunArguments()
        oversized[2] = "/" + String(
            repeating: "a",
            count: KanameLinkTunnelToolArgumentParser.maximumPathBytes
        ) + "/node"
        cases.append(oversized)

        for arguments in cases {
            #expect(throws: KanameLinkTunnelToolError.invalidArguments) {
                try parser.parse(arguments)
            }
        }
    }

    private func validRunArguments() -> [String] {
        [
            "run",
            "--node", "/opt/kaname/runtime/node",
            "--node-sha256", String(repeating: "a", count: 64),
            "--cloudflared", "/opt/kaname/cloudflared/2026.8.2/cloudflared",
            "--install-receipt",
            "/opt/kaname/cloudflared/2026.8.2/install-receipt.json",
            "--supervisor-script",
            "/opt/kaname/tunnel/Scripts/kaname-link-cloudflared-supervisor.mjs",
            "--runtime-manifest",
            "/opt/kaname/tunnel/Infrastructure/KanameLinkTunnel/cloudflared-runtime.json",
        ]
    }
}
#endif
