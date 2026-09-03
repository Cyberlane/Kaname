import Foundation
import KanameLocalCore
import Darwin

private enum ServiceError: Error {
    case usage
    case missingMachService
    case missingRequirement
    case missingCore
    case launchFailure
}

private struct Arguments {
    enum Mode { case host, install }

    let mode: Mode
    let machService: String
    let requirement: String
    let coreExecutable: URL
    let journalDirectory: URL
    let launchAgentPlist: URL?
    let localDeviceID: String?
    let localKeyID: String?

    init(_ arguments: [String]) throws {
        switch arguments.dropFirst().first {
        case "--host": mode = .host
        case "--install": mode = .install
        default: throw ServiceError.usage
        }
        guard let machService = Self.value(after: "--mach-service", in: arguments), !machService.isEmpty else {
            throw ServiceError.missingMachService
        }
        guard let requirement = Self.value(after: "--requirement", in: arguments), !requirement.isEmpty else {
            throw ServiceError.missingRequirement
        }
        guard let core = Self.value(after: "--core-executable", in: arguments) else {
            throw ServiceError.missingCore
        }
        guard let journalDirectory = Self.value(after: "--journal-directory", in: arguments) else {
            throw ServiceError.usage
        }
        self.machService = machService
        self.requirement = requirement
        coreExecutable = URL(fileURLWithPath: core)
        self.journalDirectory = URL(fileURLWithPath: journalDirectory, isDirectory: true)
        launchAgentPlist = Self.value(after: "--launch-agent-plist", in: arguments).map(URL.init(fileURLWithPath:))
        let localDeviceID = Self.value(after: "--local-device-id", in: arguments)
        let localKeyID = Self.value(after: "--local-key-id", in: arguments)
        guard (localDeviceID == nil) == (localKeyID == nil) else {
            throw ServiceError.usage
        }
        self.localDeviceID = localDeviceID
        self.localKeyID = localKeyID
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        zip(arguments, arguments.dropFirst())
            .first(where: { current, _ in current == flag })?
            .1
    }
}

private final class LocalControlService: NSObject, LocalCoreControlService {
    private let coreExecutable: URL
    private let journalDirectory: URL
    private let localDeviceID: String?
    private let localKeyID: String?

    init(
        coreExecutable: URL,
        journalDirectory: URL,
        localDeviceID: String?,
        localKeyID: String?
    ) {
        (self.coreExecutable, self.journalDirectory) = (coreExecutable, journalDirectory)
        (self.localDeviceID, self.localKeyID) = (localDeviceID, localKeyID)
    }

    func runScenario(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        guard request.count == LocalCoreRunner.maximumFixtureIDLength,
              let fixtureID = String(data: request, encoding: .utf8),
              fixtureID.range(of: "^F-[0-9]{2}$", options: .regularExpression) != nil else {
            reply(nil, "invalid_fixture")
            return
        }
        do {
            let journal = journalDirectory.appendingPathComponent("\(fixtureID).sqlite")
            let response = try Self.runCore(
                executable: coreExecutable,
                arguments: ["scenario-store", fixtureID, journal.path],
                journal: journal,
                standardInput: nil,
                timeout: 5
            )
            _ = try LocalCoreRunner.decodeScenarioReport(response)
            reply(response, "")
        } catch let error as LocalCoreRunnerError {
            switch error {
            case .timedOut: reply(nil, "core_timed_out")
            default: reply(nil, "core_failed")
            }
        } catch {
            reply(nil, "core_failed")
        }
    }

    func appendEvent(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        guard !request.isEmpty, request.count <= LocalCoreRunner.maximumResponseBytes else {
            reply(nil, "invalid_event")
            return
        }
        do {
            let journal = journalDirectory.appendingPathComponent("live-provider.sqlite")
            let response = try Self.runCore(
                executable: coreExecutable,
                arguments: [
                    "append-event",
                    journal.path,
                ],
                journal: journal,
                standardInput: request,
                timeout: 5
            )
            _ = try LocalCoreRunner.decodeEventAppendReport(response)
            reply(response, "")
        } catch let error as LocalCoreRunnerError {
            switch error {
            case .timedOut: reply(nil, "core_timed_out")
            default: reply(nil, "core_failed")
            }
        } catch {
            reply(nil, "core_failed")
        }
    }

    func authorizeAction(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWireOperation("authorize-action", request: request, reply: reply)
    }

    func recordReview(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWireOperation("record-review", request: request, reply: reply)
    }

    func replay(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWireOperation("replay", request: request, reply: reply)
    }

    func proposeMobileDevice(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWireOperation("mobile-propose", request: request, reply: reply)
    }

    func decideMobileDevice(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWireOperation("mobile-decide", request: request, reply: reply)
    }

    func recordAuthenticatedMobileSync(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        guard let localDeviceID, let localKeyID else {
            reply(nil, "mobile_not_configured")
            return
        }
        runWireOperation(
            "mobile-admit",
            request: request,
            extraArguments: [localDeviceID, localKeyID],
            reply: reply
        )
    }

    func queryWorkflowLibrary(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWorkflowLibraryOperation("workflow-library-query", request: request, reply: reply)
    }

    func setWorkflowActivation(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWorkflowLibraryOperation("workflow-library-activate", request: request, reply: reply)
    }

    func importFrozenWorkspace(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWorkflowLibraryOperation(
            "workflow-library-import-frozen",
            request: request,
            maximumRequestBytes: LocalCoreRunner.maximumWorkflowLibraryRequestBytes,
            reply: reply
        )
    }

    func inspectWorkflowRuns(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        runWireOperation(
            "workflow-run-inspect",
            request: request,
            extraArguments: [projection.path],
            permissionTarget: projection,
            reply: reply
        )
    }

    func startWorkflowRun(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        // Runs may wait on model calls and connectors; the run itself is
        // durable, so a long deadline here only bounds this one attempt.
        runWireOperation(
            "workflow-run-start",
            request: request,
            extraArguments: [projection.path, applicationSupportRoot.path],
            permissionTarget: projection,
            timeout: 600,
            reply: reply
        )
    }

    func authorizeWorkflowEffect(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        runWireOperation(
            "workflow-effect-authorize",
            request: request,
            extraArguments: [projection.path],
            permissionTarget: projection,
            reply: reply
        )
    }

    /// Fires due interval schedules. Called by the host timer; the core
    /// derives every run identity from the scheduled instant, so a repeated
    /// tick is idempotent.
    func runScheduleTick() {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        let schedules = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("schedules.json")
        guard FileManager.default.fileExists(atPath: schedules.path) else { return }
        runWireOperation(
            "workflow-schedule-tick",
            request: Data("{}".utf8),
            extraArguments: [projection.path, applicationSupportRoot.path],
            permissionTarget: projection,
            timeout: 600
        ) { _, _ in }
    }

    func purgeWorkflowRun(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        runWireOperation(
            "workflow-run-purge",
            request: request,
            extraArguments: [projection.path, applicationSupportRoot.path],
            permissionTarget: applicationSupportRoot
                .appendingPathComponent("Objects", isDirectory: true)
                .appendingPathComponent("workflow-storage.sqlite"),
            reply: reply
        )
    }

    func beginWorkflowConnectorObservation(
        _ request: Data,
        reply: @escaping (Data?, String) -> Void
    ) {
        runWorkflowConnectorObservationOperation(
            "workflow-connector-observation-begin", request: request, reply: reply
        )
    }

    func settleWorkflowConnectorObservation(
        _ request: Data,
        reply: @escaping (Data?, String) -> Void
    ) {
        runWorkflowConnectorObservationOperation(
            "workflow-connector-observation-settle", request: request, reply: reply
        )
    }

    private func runWorkflowConnectorObservationOperation(
        _ operation: String,
        request: Data,
        reply: @escaping (Data?, String) -> Void
    ) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        runWireOperation(
            operation,
            request: request,
            extraArguments: [projection.path],
            permissionTarget: projection,
            reply: reply
        )
    }

    private func runWorkflowLibraryOperation(
        _ operation: String,
        request: Data,
        maximumRequestBytes: Int = LocalCoreRunner.maximumResponseBytes,
        reply: @escaping (Data?, String) -> Void
    ) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        runWireOperation(
            operation,
            request: request,
            maximumRequestBytes: maximumRequestBytes,
            storageArgument: applicationSupportRoot,
            permissionTarget: applicationSupportRoot
                .appendingPathComponent("Workflows", isDirectory: true)
                .appendingPathComponent("workflow-library.sqlite"),
            reply: reply
        )
    }

    private func runWireOperation(
        _ operation: String,
        request: Data,
        extraArguments: [String] = [],
        maximumRequestBytes: Int = LocalCoreRunner.maximumResponseBytes,
        storageArgument: URL? = nil,
        permissionTarget: URL? = nil,
        timeout: TimeInterval = 5,
        reply: @escaping (Data?, String) -> Void
    ) {
        guard !request.isEmpty, request.count <= maximumRequestBytes else {
            reply(nil, "invalid_request")
            return
        }
        do {
            let journal = journalDirectory.appendingPathComponent("live-provider.sqlite")
            let response = try Self.runCore(
                executable: coreExecutable,
                arguments: [
                    operation,
                    (storageArgument ?? journal).path,
                ] + extraArguments,
                journal: journal,
                permissionTarget: permissionTarget ?? journal,
                standardInput: request,
                timeout: timeout
            )
            guard let wire = Self.decodeHexResponse(response) else {
                reply(nil, "core_failed")
                return
            }
            reply(wire, "")
        } catch let error as LocalCoreRunnerError {
            switch error {
            case .timedOut: reply(nil, "core_timed_out")
            default: reply(nil, "core_failed")
            }
        } catch {
            reply(nil, "core_failed")
        }
    }

    private static func decodeHexResponse(_ response: Data) -> Data? {
        let text = String(decoding: response, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count.isMultiple(of: 2) else { return nil }
        var output = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        return output
    }

    private static func runCore(
        executable: URL,
        arguments: [String],
        journal: URL,
        permissionTarget: URL? = nil,
        standardInput: Data?,
        timeout: TimeInterval
    ) throws -> Data {
        let applicationSupportRoot = journal
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let recoveryLock = try KanameRuntimeRecoveryFileLock.acquireShared(
            applicationSupportRoot: applicationSupportRoot
        )
        defer { withExtendedLifetime(recoveryLock) {} }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalCoreRunnerError.unavailable
        }
        let journalDirectory = journal.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        guard chmod(journalDirectory.path, 0o700) == 0 else {
            throw LocalCoreRunnerError.unavailable
        }
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = input
        // The workflow LLM host ships beside the core; the executor only uses it
        // when this variable names an executable that describes a model class.
        var environment = ProcessInfo.processInfo.environment
        let llmHost = executable.deletingLastPathComponent().appendingPathComponent("KanameWorkflowLlmHost")
        if FileManager.default.isExecutableFile(atPath: llmHost.path) {
            environment["KANAME_WORKFLOW_LLM_COMMAND"] = llmHost.path
        }
        let capabilityHost = executable.deletingLastPathComponent().appendingPathComponent("KanameWorkflowCapabilityHost")
        if FileManager.default.isExecutableFile(atPath: capabilityHost.path) {
            environment["KANAME_WORKFLOW_CAPABILITY_COMMAND"] = capabilityHost.path
        }
        let connectorHost = executable.deletingLastPathComponent().appendingPathComponent("KanameWorkflowConnectorHost")
        if FileManager.default.isExecutableFile(atPath: connectorHost.path) {
            environment["KANAME_WORKFLOW_EFFECT_COMMAND"] = connectorHost.path
        }
        process.environment = environment
        let timedOut = LockedFlag()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            timedOut.set()
            if process.isRunning { process.terminate() }
        }
        timer.resume()
        defer { timer.cancel() }
        try process.run()
        if let standardInput {
            try input.fileHandleForWriting.write(contentsOf: standardInput)
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        _ = standardError.fileHandleForReading.readDataToEndOfFile()
        if timedOut.value { throw LocalCoreRunnerError.timedOut }
        guard process.terminationStatus == 0 else {
            throw LocalCoreRunnerError.failed(code: "core_failed")
        }
        let permissionTarget = permissionTarget ?? journal
        guard chmod(permissionTarget.path, 0o600) == 0 else {
            throw LocalCoreRunnerError.failed(code: "journal_permissions")
        }
        return output
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: LocalControlService

    init(service: LocalControlService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        configure(connection)
        return true
    }

    private func configure(_ connection: NSXPCConnection) {
        connection.exportedInterface = NSXPCInterface(with: LocalCoreControlService.self)
        connection.exportedObject = service
        connection.activate()
    }
}

@main
private enum KanameLocalControlServiceMain {
    static func main() {
        do {
            let arguments = try Arguments(CommandLine.arguments)
            switch arguments.mode {
            case .host:
                let listener = NSXPCListener(machServiceName: arguments.machService)
                let service = LocalControlService(
                    coreExecutable: arguments.coreExecutable,
                    journalDirectory: arguments.journalDirectory,
                    localDeviceID: arguments.localDeviceID,
                    localKeyID: arguments.localKeyID
                )
                let delegate = ListenerDelegate(service: service)
                listener.delegate = delegate
                listener.setConnectionCodeSigningRequirement(arguments.requirement)
                listener.activate()
                // Scheduled workflows run from this long-lived agent, so they
                // fire even when the desktop app is closed.
                let scheduler = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.cyberlane.kaname.scheduler"))
                scheduler.schedule(deadline: .now() + 30, repeating: 60)
                scheduler.setEventHandler { service.runScheduleTick() }
                scheduler.resume()
                withExtendedLifetime((delegate, scheduler)) { dispatchMain() }
            case .install:
                try LaunchAgent.install(arguments)
            }
        } catch {
            FileHandle.standardError.write(Data("kaname-local-control-service: configuration failed\n".utf8))
            exit(64)
        }
    }
}

private enum LaunchAgent {
    static func install(_ arguments: Arguments) throws {
        guard let plist = arguments.launchAgentPlist else { throw ServiceError.usage }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let errorLog = plist.deletingLastPathComponent().appendingPathComponent("kaname-local-control-service.stderr.log")
        var programArguments = [
            executable.path, "--host", "--mach-service", arguments.machService,
            "--requirement", arguments.requirement,
            "--core-executable", arguments.coreExecutable.path,
            "--journal-directory", arguments.journalDirectory.path,
        ]
        if let localDeviceID = arguments.localDeviceID,
           let localKeyID = arguments.localKeyID {
            programArguments += [
                "--local-device-id", localDeviceID,
                "--local-key-id", localKeyID,
            ]
        }
        let propertyList: [String: Any] = [
            "Label": arguments.machService,
            "MachServices": [arguments.machService: true],
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardErrorPath": errorLog.path,
        ]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        try? launchctl(["bootout", "gui/\(getuid())/\(arguments.machService)"])
        try launchctl(["bootstrap", "gui/\(getuid())", plist.path])
    }

    private static func launchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ServiceError.launchFailure }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }

    func set() { lock.withLock { storage = true } }
}
