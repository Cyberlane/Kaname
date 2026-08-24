#if os(macOS)
import Foundation
import KanameLinkTunnelHost

enum KanameLinkTunnelToolError: Error, Equatable, Sendable {
    case invalidArguments
    case outputFailed
    case signalSetupFailed
}

enum KanameLinkTunnelToolCommand: Equatable, Sendable {
    case enrollToken
    case credentialStatus
    case run(KanameLinkTunnelSupervisorPaths)
}

struct KanameLinkTunnelToolArgumentParser: Sendable {
    static let maximumPathBytes = 4_096

    func parse(_ arguments: [String]) throws -> KanameLinkTunnelToolCommand {
        guard let command = arguments.first else {
            throw KanameLinkTunnelToolError.invalidArguments
        }
        switch command {
        case "enroll-token":
            guard arguments.count == 1 else {
                throw KanameLinkTunnelToolError.invalidArguments
            }
            return .enrollToken
        case "credential-status":
            guard arguments.count == 1 else {
                throw KanameLinkTunnelToolError.invalidArguments
            }
            return .credentialStatus
        case "run":
            return try parseRun(arguments)
        default:
            throw KanameLinkTunnelToolError.invalidArguments
        }
    }

    private func parseRun(_ arguments: [String]) throws -> KanameLinkTunnelToolCommand {
        let allowedFlags: Set<String> = [
            "--node",
            "--node-sha256",
            "--cloudflared",
            "--install-receipt",
            "--supervisor-script",
            "--runtime-manifest",
        ]
        guard arguments.count == 13 else {
            throw KanameLinkTunnelToolError.invalidArguments
        }

        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            let value = arguments[index + 1]
            guard allowedFlags.contains(flag), values[flag] == nil, !value.isEmpty else {
                throw KanameLinkTunnelToolError.invalidArguments
            }
            values[flag] = value
            index += 2
        }
        guard values.count == allowedFlags.count,
              let node = values["--node"],
              let nodeDigest = values["--node-sha256"],
              let cloudflared = values["--cloudflared"],
              let receipt = values["--install-receipt"],
              let supervisor = values["--supervisor-script"],
              let manifest = values["--runtime-manifest"] else {
            throw KanameLinkTunnelToolError.invalidArguments
        }

        do {
            return .run(try KanameLinkTunnelSupervisorPaths(
                nodeExecutableURL: exactPathURL(node),
                nodeExecutableSHA256: nodeDigest,
                cloudflaredBinaryURL: exactPathURL(cloudflared),
                installReceiptURL: exactPathURL(receipt),
                supervisorScriptURL: exactPathURL(supervisor),
                runtimeManifestURL: exactPathURL(manifest)
            ))
        } catch {
            throw KanameLinkTunnelToolError.invalidArguments
        }
    }

    private func exactPathURL(_ value: String) throws -> URL {
        guard value.utf8.count >= 2,
              value.utf8.count <= Self.maximumPathBytes,
              value.first == "/",
              value.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else {
            throw KanameLinkTunnelToolError.invalidArguments
        }
        let url = URL(fileURLWithPath: value, isDirectory: false)
        guard url.path == value, url.standardizedFileURL.path == value else {
            throw KanameLinkTunnelToolError.invalidArguments
        }
        return url
    }
}

enum KanameLinkTunnelToolOutputEvent: Equatable, Sendable {
    case credentialEnrolled
    case credentialStatus(present: Bool)
    case supervisor(processIdentifier: Int32, status: SupervisorStatus)

    enum SupervisorStatus: String, Equatable, Sendable {
        case running
        case stopped
        case exited
    }
}

protocol KanameLinkTunnelToolOutputWriting: Sendable {
    func write(_ event: KanameLinkTunnelToolOutputEvent) throws
}

protocol KanameLinkTunnelToolCredentialAccessing: Sendable {
    func enrollFromAnonymousStandardInput() throws
    func credentialIsPresent() throws -> Bool
}

protocol KanameLinkTunnelToolSupervisorControlling: Sendable {
    func launch() async throws -> Int32
    func stop() async
}

protocol KanameLinkTunnelToolSupervisorCreating: Sendable {
    func makeSupervisor(
        paths: KanameLinkTunnelSupervisorPaths
    ) -> any KanameLinkTunnelToolSupervisorControlling
}

enum KanameLinkTunnelToolRunCompletion: Equatable, Sendable {
    case signal
    case supervisorExited
}

protocol KanameLinkTunnelToolPreparedRunLifecycle: Sendable {
    func wait(forOwnedSupervisor processIdentifier: Int32) async throws
        -> KanameLinkTunnelToolRunCompletion
    func waitForOwnedSupervisorExit(processIdentifier: Int32) async throws
}

protocol KanameLinkTunnelToolRunLifecyclePreparing: Sendable {
    func prepare() throws -> any KanameLinkTunnelToolPreparedRunLifecycle
}

struct KanameLinkTunnelToolRuntime: Sendable {
    private let parser: KanameLinkTunnelToolArgumentParser
    private let credentialAccess: any KanameLinkTunnelToolCredentialAccessing
    private let supervisorFactory: any KanameLinkTunnelToolSupervisorCreating
    private let lifecycle: any KanameLinkTunnelToolRunLifecyclePreparing
    private let output: any KanameLinkTunnelToolOutputWriting

    init(
        parser: KanameLinkTunnelToolArgumentParser = .init(),
        credentialAccess: any KanameLinkTunnelToolCredentialAccessing,
        supervisorFactory: any KanameLinkTunnelToolSupervisorCreating,
        lifecycle: any KanameLinkTunnelToolRunLifecyclePreparing,
        output: any KanameLinkTunnelToolOutputWriting
    ) {
        self.parser = parser
        self.credentialAccess = credentialAccess
        self.supervisorFactory = supervisorFactory
        self.lifecycle = lifecycle
        self.output = output
    }

    func execute(arguments: [String]) async throws {
        switch try parser.parse(arguments) {
        case .enrollToken:
            try credentialAccess.enrollFromAnonymousStandardInput()
            try output.write(.credentialEnrolled)
        case .credentialStatus:
            try output.write(.credentialStatus(
                present: try credentialAccess.credentialIsPresent()
            ))
        case let .run(paths):
            let preparedLifecycle = try lifecycle.prepare()
            let supervisor = supervisorFactory.makeSupervisor(paths: paths)
            let processIdentifier = try await supervisor.launch()
            var stopped = false
            do {
                try output.write(.supervisor(
                    processIdentifier: processIdentifier,
                    status: .running
                ))
                let completion = try await preparedLifecycle.wait(
                    forOwnedSupervisor: processIdentifier
                )
                switch completion {
                case .signal:
                    await supervisor.stop()
                    stopped = true
                    try await preparedLifecycle.waitForOwnedSupervisorExit(
                        processIdentifier: processIdentifier
                    )
                    try output.write(.supervisor(
                        processIdentifier: processIdentifier,
                        status: .stopped
                    ))
                case .supervisorExited:
                    try output.write(.supervisor(
                        processIdentifier: processIdentifier,
                        status: .exited
                    ))
                }
            } catch {
                if !stopped {
                    await supervisor.stop()
                    try? await preparedLifecycle.waitForOwnedSupervisorExit(
                        processIdentifier: processIdentifier
                    )
                }
                throw error
            }
        }
    }
}
#endif
