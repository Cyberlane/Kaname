#if os(macOS)
import Foundation
import Testing
@testable import KanameLinkTunnelHost

@Suite(.serialized)
struct KanameLinkTunnelSupervisorLauncherTests {
    @Test
    func launcherVerifiesExactPathsThenFeedsTokenOnlyThroughProcessInput() async throws {
        let tokenData = Data("eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwifQ==".utf8)
        let events = TunnelLaunchEventRecorder()
        let store = StubCredentialStore(tokenData: tokenData, events: events)
        let verifier = RecordingArtifactVerifier(events: events)
        let processLauncher = RecordingSupervisorProcessLauncher(events: events)
        let paths = try fixturePaths()
        let launcher = KanameLinkTunnelSupervisorLauncher(
            paths: paths,
            credentialStore: store,
            artifactVerifier: verifier,
            processLauncher: processLauncher
        )

        let processIdentifier = try await launcher.launch()

        #expect(processIdentifier == 4_310)
        #expect(verifier.verifiedPaths == [paths])
        #expect(processLauncher.tokenData == tokenData)
        let request = try #require(processLauncher.request)
        #expect(request.executableURL == paths.nodeExecutableURL)
        #expect(request.arguments == [
            paths.supervisorScriptURL.path,
            "--binary", paths.cloudflaredBinaryURL.path,
            "--receipt", paths.installReceiptURL.path,
            "--manifest", paths.runtimeManifestURL.path,
        ])
        #expect(request.arguments.joined(separator: " ").contains(String(decoding: tokenData, as: UTF8.self)) == false)
        #expect(request.environment == [
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin",
        ])
        #expect(request.environment.keys.contains("TUNNEL_TOKEN") == false)
        #expect(request.environment.keys.contains("CLOUDFLARE_API_TOKEN") == false)
        #expect(store.loadCount == 1)
        #expect(store.deleteCount == 0)
        #expect(events.values == [.verify, .loadCredential, .launchProcess])
    }

    @Test
    func launcherRejectsSecondOwnedSupervisorAndStopsOnlyThatProcess() async throws {
        let store = StubCredentialStore(
            tokenData: Data("eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwifQ==".utf8)
        )
        let processLauncher = RecordingSupervisorProcessLauncher()
        let launcher = KanameLinkTunnelSupervisorLauncher(
            paths: try fixturePaths(),
            credentialStore: store,
            artifactVerifier: RecordingArtifactVerifier(),
            processLauncher: processLauncher
        )
        _ = try await launcher.launch()

        await #expect(throws: KanameLinkTunnelSupervisorFailure.alreadyRunning) {
            try await launcher.launch()
        }
        await launcher.stop()

        #expect(processLauncher.process.terminateCount == 1)
        #expect(store.deleteCount == 0)
    }

    @Test
    func pathContractRejectsSubstitutedScriptsAndInvalidRuntimeDigest() throws {
        let valid = try fixturePaths()
        #expect(throws: KanameLinkTunnelSupervisorFailure.invalidPath) {
            _ = try KanameLinkTunnelSupervisorPaths(
                nodeExecutableURL: valid.nodeExecutableURL,
                nodeExecutableSHA256: valid.nodeExecutableSHA256,
                cloudflaredBinaryURL: valid.cloudflaredBinaryURL,
                installReceiptURL: valid.installReceiptURL,
                supervisorScriptURL: valid.supervisorScriptURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("substitute.mjs"),
                runtimeManifestURL: valid.runtimeManifestURL
            )
        }
        #expect(throws: KanameLinkTunnelSupervisorFailure.invalidDigest) {
            _ = try KanameLinkTunnelSupervisorPaths(
                nodeExecutableURL: valid.nodeExecutableURL,
                nodeExecutableSHA256: "not-a-digest",
                cloudflaredBinaryURL: valid.cloudflaredBinaryURL,
                installReceiptURL: valid.installReceiptURL,
                supervisorScriptURL: valid.supervisorScriptURL,
                runtimeManifestURL: valid.runtimeManifestURL
            )
        }
    }

    @Test
    func failedArtifactVerificationNeverLoadsOrDeliversTheCredential() async throws {
        let events = TunnelLaunchEventRecorder()
        let store = StubCredentialStore(
            tokenData: Data("eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwifQ==".utf8),
            events: events
        )
        let processLauncher = RecordingSupervisorProcessLauncher(events: events)
        let launcher = KanameLinkTunnelSupervisorLauncher(
            paths: try fixturePaths(),
            credentialStore: store,
            artifactVerifier: RecordingArtifactVerifier(events: events, shouldFail: true),
            processLauncher: processLauncher
        )

        await #expect(throws: KanameLinkTunnelSupervisorFailure.artifactMismatch("injected")) {
            try await launcher.launch()
        }

        #expect(events.values == [.verify])
        #expect(store.loadCount == 0)
        #expect(store.deleteCount == 0)
        #expect(processLauncher.request == nil)
        #expect(processLauncher.tokenData == nil)
    }

    @Test
    func explicitLocalDeleteDoesNotLaunchAProcessOrImplyRemoteRevocation() async throws {
        let store = StubCredentialStore(
            tokenData: Data("eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwifQ==".utf8)
        )
        let processLauncher = RecordingSupervisorProcessLauncher()
        let launcher = KanameLinkTunnelSupervisorLauncher(
            paths: try fixturePaths(),
            credentialStore: store,
            artifactVerifier: RecordingArtifactVerifier(),
            processLauncher: processLauncher
        )

        try await launcher.deleteLocalCredential()

        #expect(store.deleteCount == 1)
        #expect(store.loadCount == 0)
        #expect(processLauncher.request == nil)
    }

    private func fixturePaths() throws -> KanameLinkTunnelSupervisorPaths {
        try KanameLinkTunnelSupervisorPaths(
            nodeExecutableURL: URL(fileURLWithPath: "/opt/kaname/runtime/node"),
            nodeExecutableSHA256: String(repeating: "a", count: 64),
            cloudflaredBinaryURL: URL(fileURLWithPath: "/opt/kaname/cloudflared/2026.8.2/cloudflared"),
            installReceiptURL: URL(fileURLWithPath: "/opt/kaname/cloudflared/2026.8.2/install-receipt.json"),
            supervisorScriptURL: URL(fileURLWithPath: "/opt/kaname/tunnel/Scripts/kaname-link-cloudflared-supervisor.mjs"),
            runtimeManifestURL: URL(fileURLWithPath: "/opt/kaname/tunnel/Infrastructure/KanameLinkTunnel/cloudflared-runtime.json")
        )
    }
}

private final class StubCredentialStore: KanameLinkTunnelCredentialStoring, @unchecked Sendable {
    let tokenData: Data
    let events: TunnelLaunchEventRecorder?
    private(set) var loadCount = 0
    private(set) var deleteCount = 0

    init(tokenData: Data, events: TunnelLaunchEventRecorder? = nil) {
        self.tokenData = tokenData
        self.events = events
    }

    func replaceToken(_: KanameLinkTunnelToken) throws {}

    func loadToken() throws -> KanameLinkTunnelToken {
        events?.append(.loadCredential)
        loadCount += 1
        return try KanameLinkTunnelToken(data: tokenData)
    }

    func deleteToken() throws {
        deleteCount += 1
    }
}

private final class RecordingArtifactVerifier:
    KanameLinkTunnelArtifactVerifying, @unchecked Sendable
{
    let events: TunnelLaunchEventRecorder?
    let shouldFail: Bool
    private(set) var verifiedPaths: [KanameLinkTunnelSupervisorPaths] = []

    init(events: TunnelLaunchEventRecorder? = nil, shouldFail: Bool = false) {
        self.events = events
        self.shouldFail = shouldFail
    }

    func verify(_ paths: KanameLinkTunnelSupervisorPaths) throws {
        events?.append(.verify)
        if shouldFail {
            throw KanameLinkTunnelSupervisorFailure.artifactMismatch("injected")
        }
        verifiedPaths.append(paths)
    }
}

private final class RecordingSupervisorProcessLauncher:
    KanameLinkTunnelSupervisorProcessLaunching, @unchecked Sendable
{
    let events: TunnelLaunchEventRecorder?
    private(set) var request: KanameLinkTunnelSupervisorLaunchRequest?
    private(set) var tokenData: Data?
    let process = RecordingRunningSupervisor()

    init(events: TunnelLaunchEventRecorder? = nil) {
        self.events = events
    }

    func launch(
        request: KanameLinkTunnelSupervisorLaunchRequest,
        token: KanameLinkTunnelToken
    ) throws -> any KanameLinkTunnelRunningSupervisor {
        events?.append(.launchProcess)
        self.request = request
        token.withData { tokenData = Data($0) }
        return process
    }
}

private final class RecordingRunningSupervisor:
    KanameLinkTunnelRunningSupervisor, @unchecked Sendable
{
    let processIdentifier: Int32 = 4_310
    private(set) var isRunning = true
    private(set) var terminateCount = 0

    func terminate() {
        terminateCount += 1
        isRunning = false
    }
}

private enum TunnelLaunchEvent: Equatable {
    case verify
    case loadCredential
    case launchProcess
}

private final class TunnelLaunchEventRecorder: @unchecked Sendable {
    private(set) var values: [TunnelLaunchEvent] = []

    func append(_ event: TunnelLaunchEvent) {
        values.append(event)
    }
}
#endif
