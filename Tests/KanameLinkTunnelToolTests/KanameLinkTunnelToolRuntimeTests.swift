#if os(macOS)
import Foundation
import KanameLinkTunnelHost
import Testing
@testable import KanameLinkTunnelTool

@Suite(.serialized)
struct KanameLinkTunnelToolRuntimeTests {
    @Test
    func enrollDelegatesOnlyToAnonymousStandardInputAndEmitsSafeReceipt() async throws {
        let fixture = RuntimeFixture()

        try await fixture.runtime.execute(arguments: ["enroll-token"])

        #expect(fixture.credentials.enrollmentCount == 1)
        #expect(fixture.credentials.statusCount == 0)
        #expect(fixture.supervisorFactory.creationCount == 0)
        #expect(fixture.lifecycle.prepareCount == 0)
        #expect(fixture.output.events == [.credentialEnrolled])
        #expect(try String(decoding: KanameLinkTunnelToolJSON.encode(.credentialEnrolled), as: UTF8.self) ==
            "{\"ok\":true,\"operation\":\"enroll-token\",\"status\":\"stored\"}\n")
    }

    @Test(arguments: [true, false])
    func credentialStatusReportsOnlyPresence(_ present: Bool) async throws {
        let fixture = RuntimeFixture(credentialPresent: present)

        try await fixture.runtime.execute(arguments: ["credential-status"])

        #expect(fixture.credentials.enrollmentCount == 0)
        #expect(fixture.credentials.statusCount == 1)
        #expect(fixture.output.events == [.credentialStatus(present: present)])
        let encoded = try String(
            decoding: KanameLinkTunnelToolJSON.encode(.credentialStatus(present: present)),
            as: UTF8.self
        )
        let expectedStatus = present ? "present" : "missing"
        let expected = "{\"ok\":true,\"operation\":\"credential-status\",\"status\":\"" +
            expectedStatus + "\"}\n"
        #expect(encoded == expected)
    }

    @Test
    func signalStopsOnlyTheOwnedSupervisorAndEmitsOnlyPIDAndStatus() async throws {
        let events = RuntimeEventRecorder()
        let fixture = RuntimeFixture(completion: .signal, recorder: events)

        try await fixture.runtime.execute(arguments: validRunArguments())

        #expect(fixture.supervisorFactory.creationCount == 1)
        #expect(fixture.supervisor.launchCount == 1)
        #expect(fixture.supervisor.stopCount == 1)
        #expect(fixture.lifecycle.prepared.waitedProcessIdentifiers == [4_310])
        #expect(fixture.output.events == [
            .supervisor(processIdentifier: 4_310, status: .running),
            .supervisor(processIdentifier: 4_310, status: .stopped),
        ])
        #expect(events.values == [
            .prepareLifecycle,
            .createSupervisor,
            .launchSupervisor,
            .writeOutput,
            .waitForSupervisor,
            .stopSupervisor,
            .waitForSupervisorExit,
            .writeOutput,
        ])
        let encoded = try String(
            decoding: KanameLinkTunnelToolJSON.encode(
                .supervisor(processIdentifier: 4_310, status: .running)
            ),
            as: UTF8.self
        )
        #expect(encoded == "{\"pid\":4310,\"status\":\"running\"}\n")
    }

    @Test
    func naturalSupervisorExitDoesNotSendATerminationSignal() async throws {
        let fixture = RuntimeFixture(completion: .supervisorExited)

        try await fixture.runtime.execute(arguments: validRunArguments())

        #expect(fixture.supervisor.stopCount == 0)
        #expect(fixture.output.events == [
            .supervisor(processIdentifier: 4_310, status: .running),
            .supervisor(processIdentifier: 4_310, status: .exited),
        ])
    }

    @Test
    func postLaunchFailureStopsTheOwnedSupervisorWithoutCredentialOutput() async {
        let fixture = RuntimeFixture(outputFailureIndex: 0)

        await #expect(throws: KanameLinkTunnelToolError.outputFailed) {
            try await fixture.runtime.execute(arguments: validRunArguments())
        }

        #expect(fixture.supervisor.launchCount == 1)
        #expect(fixture.supervisor.stopCount == 1)
        #expect(fixture.lifecycle.prepared.exitWaitedProcessIdentifiers == [4_310])
        #expect(fixture.output.events.isEmpty)
    }

    @Test
    func safeFailureEncodingNeverUsesAnErrorDescription() throws {
        let code = KanameLinkTunnelToolSafeFailure.code(
            for: KanameLinkTunnelCredentialError.keychainFailure(-25_300)
        )
        let encoded = String(
            decoding: try KanameLinkTunnelToolJSON.encodeFailure(code: code),
            as: UTF8.self
        )

        #expect(code == "credential_access_failed")
        #expect(encoded == "{\"error\":\"credential_access_failed\",\"ok\":false}\n")
        #expect(encoded.contains("-25300") == false)
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

private final class RuntimeFixture: @unchecked Sendable {
    let credentials: StubToolCredentialAccess
    let supervisor: StubToolSupervisor
    let supervisorFactory: StubToolSupervisorFactory
    let lifecycle: StubToolLifecycleFactory
    let output: RecordingToolOutput
    let runtime: KanameLinkTunnelToolRuntime

    init(
        credentialPresent: Bool = true,
        completion: KanameLinkTunnelToolRunCompletion = .signal,
        outputFailureIndex: Int? = nil,
        recorder: RuntimeEventRecorder? = nil
    ) {
        let credentials = StubToolCredentialAccess(present: credentialPresent)
        let supervisor = StubToolSupervisor(recorder: recorder)
        let supervisorFactory = StubToolSupervisorFactory(
            supervisor: supervisor,
            recorder: recorder
        )
        let lifecycle = StubToolLifecycleFactory(
            completion: completion,
            recorder: recorder
        )
        let output = RecordingToolOutput(
            failureIndex: outputFailureIndex,
            recorder: recorder
        )
        self.credentials = credentials
        self.supervisor = supervisor
        self.supervisorFactory = supervisorFactory
        self.lifecycle = lifecycle
        self.output = output
        runtime = KanameLinkTunnelToolRuntime(
            credentialAccess: credentials,
            supervisorFactory: supervisorFactory,
            lifecycle: lifecycle,
            output: output
        )
    }
}

private final class StubToolCredentialAccess:
    KanameLinkTunnelToolCredentialAccessing, @unchecked Sendable
{
    let present: Bool
    private(set) var enrollmentCount = 0
    private(set) var statusCount = 0

    init(present: Bool) {
        self.present = present
    }

    func enrollFromAnonymousStandardInput() throws {
        enrollmentCount += 1
    }

    func credentialIsPresent() throws -> Bool {
        statusCount += 1
        return present
    }
}

private final class StubToolSupervisor:
    KanameLinkTunnelToolSupervisorControlling, @unchecked Sendable
{
    let recorder: RuntimeEventRecorder?
    private(set) var launchCount = 0
    private(set) var stopCount = 0

    init(recorder: RuntimeEventRecorder?) {
        self.recorder = recorder
    }

    func launch() async throws -> Int32 {
        recorder?.append(.launchSupervisor)
        launchCount += 1
        return 4_310
    }

    func stop() async {
        recorder?.append(.stopSupervisor)
        stopCount += 1
    }
}

private final class StubToolSupervisorFactory:
    KanameLinkTunnelToolSupervisorCreating, @unchecked Sendable
{
    let supervisor: StubToolSupervisor
    let recorder: RuntimeEventRecorder?
    private(set) var creationCount = 0
    private(set) var paths: [KanameLinkTunnelSupervisorPaths] = []

    init(supervisor: StubToolSupervisor, recorder: RuntimeEventRecorder?) {
        self.supervisor = supervisor
        self.recorder = recorder
    }

    func makeSupervisor(
        paths: KanameLinkTunnelSupervisorPaths
    ) -> any KanameLinkTunnelToolSupervisorControlling {
        recorder?.append(.createSupervisor)
        creationCount += 1
        self.paths.append(paths)
        return supervisor
    }
}

private final class StubToolPreparedLifecycle:
    KanameLinkTunnelToolPreparedRunLifecycle, @unchecked Sendable
{
    let completion: KanameLinkTunnelToolRunCompletion
    let recorder: RuntimeEventRecorder?
    private(set) var waitedProcessIdentifiers: [Int32] = []
    private(set) var exitWaitedProcessIdentifiers: [Int32] = []

    init(completion: KanameLinkTunnelToolRunCompletion, recorder: RuntimeEventRecorder?) {
        self.completion = completion
        self.recorder = recorder
    }

    func wait(
        forOwnedSupervisor processIdentifier: Int32
    ) async throws -> KanameLinkTunnelToolRunCompletion {
        recorder?.append(.waitForSupervisor)
        waitedProcessIdentifiers.append(processIdentifier)
        return completion
    }

    func waitForOwnedSupervisorExit(processIdentifier: Int32) async throws {
        recorder?.append(.waitForSupervisorExit)
        exitWaitedProcessIdentifiers.append(processIdentifier)
    }
}

private final class StubToolLifecycleFactory:
    KanameLinkTunnelToolRunLifecyclePreparing, @unchecked Sendable
{
    let prepared: StubToolPreparedLifecycle
    let recorder: RuntimeEventRecorder?
    private(set) var prepareCount = 0

    init(completion: KanameLinkTunnelToolRunCompletion, recorder: RuntimeEventRecorder?) {
        prepared = StubToolPreparedLifecycle(completion: completion, recorder: recorder)
        self.recorder = recorder
    }

    func prepare() throws -> any KanameLinkTunnelToolPreparedRunLifecycle {
        recorder?.append(.prepareLifecycle)
        prepareCount += 1
        return prepared
    }
}

private final class RecordingToolOutput:
    KanameLinkTunnelToolOutputWriting, @unchecked Sendable
{
    let failureIndex: Int?
    let recorder: RuntimeEventRecorder?
    private(set) var events: [KanameLinkTunnelToolOutputEvent] = []

    init(failureIndex: Int?, recorder: RuntimeEventRecorder?) {
        self.failureIndex = failureIndex
        self.recorder = recorder
    }

    func write(_ event: KanameLinkTunnelToolOutputEvent) throws {
        recorder?.append(.writeOutput)
        if events.count == failureIndex {
            throw KanameLinkTunnelToolError.outputFailed
        }
        events.append(event)
    }
}

private enum RuntimeEvent: Equatable {
    case prepareLifecycle
    case createSupervisor
    case launchSupervisor
    case writeOutput
    case waitForSupervisor
    case waitForSupervisorExit
    case stopSupervisor
}

private final class RuntimeEventRecorder: @unchecked Sendable {
    private(set) var values: [RuntimeEvent] = []

    func append(_ event: RuntimeEvent) {
        values.append(event)
    }
}
#endif
