#if os(macOS)
import Darwin
import CoreFoundation
import Foundation

public struct KanameLinkGatewayRuntimeConfiguration: Equatable, Sendable {
    public static let standard = try! KanameLinkGatewayRuntimeConfiguration()

    public let startupTimeout: TimeInterval
    public let healthRequestTimeout: TimeInterval
    public let maximumStartupLineBytes: Int
    public let maximumSuppressedDiagnosticBytes: Int
    public let bindAddress: String

    public init(
        startupTimeout: TimeInterval = 4,
        healthRequestTimeout: TimeInterval = 0.35,
        maximumStartupLineBytes: Int = 4 * 1_024,
        maximumSuppressedDiagnosticBytes: Int = 8 * 1_024,
        bindAddress: String = "127.0.0.1:43110"
    ) throws {
        guard startupTimeout >= 0.1, startupTimeout <= 15,
              healthRequestTimeout >= 0.05, healthRequestTimeout <= 2,
              maximumStartupLineBytes >= 256, maximumStartupLineBytes <= 16 * 1_024,
              maximumSuppressedDiagnosticBytes >= 256,
              maximumSuppressedDiagnosticBytes <= 64 * 1_024,
              Self.isValidLoopbackBindAddress(bindAddress) else {
            throw KanameLinkGatewayRuntimeFailure.invalidConfiguration
        }
        self.startupTimeout = startupTimeout
        self.healthRequestTimeout = healthRequestTimeout
        self.maximumStartupLineBytes = maximumStartupLineBytes
        self.maximumSuppressedDiagnosticBytes = maximumSuppressedDiagnosticBytes
        self.bindAddress = bindAddress
    }

    private static func isValidLoopbackBindAddress(_ value: String) -> Bool {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "127.0.0.1",
              let port = UInt16(components[1]),
              port > 0,
              value == "127.0.0.1:\(port)" else { return false }
        return true
    }

    var healthURL: URL { URL(string: "http://\(bindAddress)/health")! }
}

public enum KanameLinkGatewayRuntimeFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case executableUnavailable
    case invalidStateRoot
    case alreadyStarting
    case portOccupied
    case launchFailed
    case startupTimedOut
    case startupOutputTooLarge
    case malformedStartup
    case startupMismatch
    case healthTimedOut
    case childExited(status: Int32)
    case startupCancelled
    case notRunning
    case terminationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The Link gateway runtime limits are invalid."
        case .executableUnavailable:
            "The exact bundled Link gateway executable is unavailable."
        case .invalidStateRoot:
            "The private Link gateway state directory is invalid."
        case .alreadyStarting:
            "The Link gateway is already starting."
        case .portOccupied:
            "The private Link gateway port is already occupied."
        case .launchFailed:
            "The bundled Link gateway could not start."
        case .startupTimedOut:
            "The Link gateway did not produce its startup receipt in time."
        case .startupOutputTooLarge:
            "The Link gateway startup receipt exceeded its size limit."
        case .malformedStartup:
            "The Link gateway produced a malformed startup receipt."
        case .startupMismatch:
            "The Link gateway startup receipt did not match its exact local endpoint."
        case .healthTimedOut:
            "The Link gateway did not pass its exact local health check."
        case let .childExited(status):
            "The Link gateway exited unexpectedly with status \(status)."
        case .startupCancelled:
            "Link gateway startup was cancelled."
        case .notRunning:
            "The Link gateway is not running."
        case .terminationFailed:
            "The exact Link gateway child could not be terminated."
        }
    }
}

public enum KanameLinkGatewayRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed(KanameLinkGatewayRuntimeFailure)
}

public struct KanameLinkGatewayRuntimeStatus: Equatable, Sendable {
    public let state: KanameLinkGatewayRuntimeState
    public let ownedProcessIdentifier: Int32?
    public let bindAddress: String
    public let healthVerified: Bool

    public init(
        state: KanameLinkGatewayRuntimeState,
        ownedProcessIdentifier: Int32?,
        bindAddress: String,
        healthVerified: Bool
    ) {
        self.state = state
        self.ownedProcessIdentifier = ownedProcessIdentifier
        self.bindAddress = bindAddress
        self.healthVerified = healthVerified
    }
}

/// Owns only the loopback Rust gateway child. Cloudflare, tunnel, and relay
/// supervision are deliberately outside this component.
public actor KanameLinkGatewayRuntime {
    public static let bindAddress = "127.0.0.1:43110"
    public static let healthURL = URL(string: "http://127.0.0.1:43110/health")!

    private let executableURL: URL
    private let stateRootURL: URL
    private let configuration: KanameLinkGatewayRuntimeConfiguration
    private var runtimeState: KanameLinkGatewayRuntimeState = .stopped
    private var healthVerified = false
    private var ownedProcess: KanameLinkOwnedGatewayProcess?
    private var generation: UUID?
    private var intentionallyStoppingGeneration: UUID?

    public init(
        executableURL: URL,
        stateRootURL: URL,
        configuration: KanameLinkGatewayRuntimeConfiguration = .standard
    ) throws {
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              executableURL.lastPathComponent == "kaname-link-gateway" else {
            throw KanameLinkGatewayRuntimeFailure.executableUnavailable
        }
        guard stateRootURL.isFileURL,
              stateRootURL.path.hasPrefix("/"),
              stateRootURL.standardizedFileURL.pathComponents.count > 2 else {
            throw KanameLinkGatewayRuntimeFailure.invalidStateRoot
        }
        self.executableURL = executableURL.standardizedFileURL
        self.stateRootURL = stateRootURL.standardizedFileURL
        self.configuration = configuration
    }

    deinit {
        _ = ownedProcess?.terminateOwnedChild()
    }

    public func status() -> KanameLinkGatewayRuntimeStatus {
        KanameLinkGatewayRuntimeStatus(
            state: runtimeState,
            ownedProcessIdentifier: ownedProcess?.processIdentifier,
            bindAddress: configuration.bindAddress,
            healthVerified: healthVerified
        )
    }

    @discardableResult
    public func start() async throws -> KanameLinkGatewayRuntimeStatus {
        if let ownedProcess, ownedProcess.isRunning, runtimeState == .running {
            return status()
        }
        guard runtimeState != .starting else {
            throw KanameLinkGatewayRuntimeFailure.alreadyStarting
        }

        if let staleProcess = ownedProcess, !staleProcess.isRunning {
            staleProcess.closePipes()
            ownedProcess = nil
            generation = nil
            healthVerified = false
        }

        do {
            try validateExecutable()
            try preparePrivateStateRoot()
            try Self.requireAvailableLoopbackPort(configuration.bindAddress)
        } catch let failure as KanameLinkGatewayRuntimeFailure {
            runtimeState = .failed(failure)
            healthVerified = false
            throw failure
        }

        let nextGeneration = UUID()
        generation = nextGeneration
        intentionallyStoppingGeneration = nil
        runtimeState = .starting
        healthVerified = false

        let sink = KanameLinkGatewayOutputSink(
            maximumStartupLineBytes: configuration.maximumStartupLineBytes,
            maximumSuppressedDiagnosticBytes: configuration.maximumSuppressedDiagnosticBytes
        )
        let exitLatch = KanameLinkGatewayExitLatch()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "serve",
            "--state-root", stateRootURL.path,
            "--bind", configuration.bindAddress,
        ]
        process.environment = [
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            sink.consumeStandardOutput(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            sink.consumeDiagnostic(handle.availableData)
        }
        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            let processIdentifier = terminated.processIdentifier
            sink.processExited(status: status)
            exitLatch.signal()
            Task {
                await self?.observeExit(
                    processIdentifier: processIdentifier,
                    generation: nextGeneration,
                    status: status
                )
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            runtimeState = .failed(.launchFailed)
            generation = nil
            throw KanameLinkGatewayRuntimeFailure.launchFailed
        }

        let owned = KanameLinkOwnedGatewayProcess(
            process: process,
            outputPipe: outputPipe,
            errorPipe: errorPipe,
            exitLatch: exitLatch
        )
        ownedProcess = owned

        do {
            let startup = await sink.waitForStartup(timeout: configuration.startupTimeout)
            try requireCurrent(owned, generation: nextGeneration)
            switch startup {
            case let .line(line):
                try validateStartupLine(line)
            case .timedOut:
                throw KanameLinkGatewayRuntimeFailure.startupTimedOut
            case .oversized:
                throw KanameLinkGatewayRuntimeFailure.startupOutputTooLarge
            case let .exited(status):
                throw KanameLinkGatewayRuntimeFailure.childExited(status: status)
            }

            try await waitForHealth(owned, generation: nextGeneration)
            try requireCurrent(owned, generation: nextGeneration)
            guard owned.isRunning else {
                throw KanameLinkGatewayRuntimeFailure.childExited(
                    status: owned.terminationStatusIfAvailable ?? -1
                )
            }
            healthVerified = true
            runtimeState = .running
            return status()
        } catch let failure as KanameLinkGatewayRuntimeFailure {
            await failStartup(failure, owned: owned, generation: nextGeneration)
            throw failure
        } catch {
            await failStartup(.launchFailed, owned: owned, generation: nextGeneration)
            throw KanameLinkGatewayRuntimeFailure.launchFailed
        }
    }

    public func stop() async throws {
        guard let ownedProcess else {
            runtimeState = .stopped
            healthVerified = false
            generation = nil
            return
        }
        let stoppingGeneration = generation
        intentionallyStoppingGeneration = stoppingGeneration
        healthVerified = false
        let terminated = await Task.detached {
            ownedProcess.terminateOwnedChild()
        }.value
        guard terminated else {
            runtimeState = .failed(.terminationFailed)
            throw KanameLinkGatewayRuntimeFailure.terminationFailed
        }
        if self.ownedProcess?.processIdentifier == ownedProcess.processIdentifier {
            ownedProcess.closePipes()
            self.ownedProcess = nil
        }
        generation = nil
        intentionallyStoppingGeneration = nil
        runtimeState = .stopped
    }

    /// Supplies the same exact executable with Rust's live admin arguments.
    /// Request/response mapping remains a separate protocol-layer concern.
    public func makeAdminRunner(
        configuration: KanameLinkProcessRunnerConfiguration = .standard
    ) throws -> KanameLinkAdminProcessRunner {
        guard runtimeState == .running,
              healthVerified,
              let ownedProcess,
              ownedProcess.isRunning else {
            throw KanameLinkGatewayRuntimeFailure.notRunning
        }
        return try KanameLinkAdminProcessRunner(
            executableURL: executableURL,
            arguments: ["admin", "--state-root", stateRootURL.path],
            configuration: configuration
        )
    }

    private func validateExecutable() throws {
        let values = try? executableURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw KanameLinkGatewayRuntimeFailure.executableUnavailable
        }
    }

    private func preparePrivateStateRoot() throws {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: stateRootURL.path) {
                let values = try stateRootURL.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw KanameLinkGatewayRuntimeFailure.invalidStateRoot
                }
            } else {
                try manager.createDirectory(
                    at: stateRootURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try manager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: stateRootURL.path
            )
        } catch let failure as KanameLinkGatewayRuntimeFailure {
            throw failure
        } catch {
            throw KanameLinkGatewayRuntimeFailure.invalidStateRoot
        }
    }

    private func waitForHealth(
        _ owned: KanameLinkOwnedGatewayProcess,
        generation: UUID
    ) async throws {
        let deadline = Date().addingTimeInterval(configuration.startupTimeout)
        while Date() < deadline {
            try requireCurrent(owned, generation: generation)
            guard owned.isRunning else {
                throw KanameLinkGatewayRuntimeFailure.childExited(
                    status: owned.terminationStatusIfAvailable ?? -1
                )
            }
            if await Self.probeExactHealth(
                url: configuration.healthURL,
                timeout: configuration.healthRequestTimeout
            ) {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw KanameLinkGatewayRuntimeFailure.healthTimedOut
    }

    private func requireCurrent(
        _ owned: KanameLinkOwnedGatewayProcess,
        generation: UUID
    ) throws {
        guard self.generation == generation,
              ownedProcess?.processIdentifier == owned.processIdentifier else {
            if case let .failed(failure) = runtimeState,
               case .childExited = failure {
                throw failure
            }
            throw KanameLinkGatewayRuntimeFailure.startupCancelled
        }
    }

    private func failStartup(
        _ failure: KanameLinkGatewayRuntimeFailure,
        owned: KanameLinkOwnedGatewayProcess,
        generation: UUID
    ) async {
        guard self.generation == generation else { return }
        intentionallyStoppingGeneration = generation
        _ = await Task.detached {
            owned.terminateOwnedChild()
        }.value
        owned.closePipes()
        if ownedProcess?.processIdentifier == owned.processIdentifier {
            ownedProcess = nil
        }
        self.generation = nil
        intentionallyStoppingGeneration = nil
        healthVerified = false
        runtimeState = .failed(failure)
    }

    private func observeExit(
        processIdentifier: Int32,
        generation: UUID,
        status: Int32
    ) {
        guard self.generation == generation,
              ownedProcess?.processIdentifier == processIdentifier else { return }
        ownedProcess?.closePipes()
        ownedProcess = nil
        self.generation = nil
        healthVerified = false
        if intentionallyStoppingGeneration == generation {
            intentionallyStoppingGeneration = nil
            runtimeState = .stopped
        } else {
            runtimeState = .failed(.childExited(status: status))
        }
    }

    private func validateStartupLine(_ line: Data) throws {
        guard line.count >= 2,
              line.first == Character("{").asciiValue,
              line.last == Character("}").asciiValue,
              let decoded = try? JSONSerialization.jsonObject(with: line),
              let object = decoded as? [String: Any] else {
            throw KanameLinkGatewayRuntimeFailure.malformedStartup
        }
        guard
              Set(object.keys) == Set(["schemaVersion", "requestID", "ok", "result"]),
              let schemaVersion = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(schemaVersion) != CFBooleanGetTypeID(),
              schemaVersion.intValue == 1,
              schemaVersion.doubleValue == 1,
              object["requestID"] as? String == "startup",
              let ok = object["ok"] as? NSNumber,
              CFGetTypeID(ok) == CFBooleanGetTypeID(),
              ok.boolValue,
              let result = object["result"] as? [String: Any],
              Set(result.keys) == Set(["listeningAddress"]),
              result["listeningAddress"] as? String == configuration.bindAddress else {
            throw KanameLinkGatewayRuntimeFailure.startupMismatch
        }
    }

    private static func requireAvailableLoopbackPort(_ bindAddress: String) throws {
        let components = bindAddress.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "127.0.0.1",
              let port = UInt16(components[1]),
              port > 0 else {
            throw KanameLinkGatewayRuntimeFailure.invalidConfiguration
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KanameLinkGatewayRuntimeFailure.portOccupied
        }
        defer { Darwin.close(descriptor) }
        var reuseAddress: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw KanameLinkGatewayRuntimeFailure.portOccupied
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard result == 0 else {
            throw KanameLinkGatewayRuntimeFailure.portOccupied
        }
    }

    private static func probeExactHealth(url: URL, timeout: TimeInterval) async -> Bool {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = timeout
        sessionConfiguration.timeoutIntervalForResource = timeout
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.connectionProxyDictionary = [:]
        let delegate = KanameLinkNoRedirectDelegate()
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard data.isEmpty,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 204,
                  http.url == url else { return false }
            return true
        } catch {
            return false
        }
    }
}

private enum KanameLinkGatewayStartupResult: Sendable {
    case line(Data)
    case timedOut
    case oversized
    case exited(Int32)
}

private final class KanameLinkGatewayOutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private let maximumStartupLineBytes: Int
    private let maximumSuppressedDiagnosticBytes: Int
    private var startupBuffer = Data()
    private var startupResult: KanameLinkGatewayStartupResult?
    private var suppressedDiagnosticBytes = 0

    init(maximumStartupLineBytes: Int, maximumSuppressedDiagnosticBytes: Int) {
        self.maximumStartupLineBytes = maximumStartupLineBytes
        self.maximumSuppressedDiagnosticBytes = maximumSuppressedDiagnosticBytes
    }

    func consumeStandardOutput(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard startupResult == nil else {
            suppress(incoming.count)
            return
        }
        let retainedCapacity = maximumStartupLineBytes + 1 - startupBuffer.count
        let retainedCount = max(0, min(incoming.count, retainedCapacity))
        if retainedCount > 0 {
            startupBuffer.append(contentsOf: incoming.prefix(retainedCount))
        }
        suppress(incoming.count - retainedCount)
        if let newline = startupBuffer.firstIndex(of: 0x0A) {
            let line = Data(startupBuffer[..<newline])
            let trailingCount = startupBuffer.distance(
                from: startupBuffer.index(after: newline),
                to: startupBuffer.endIndex
            )
            startupBuffer.removeAll(keepingCapacity: false)
            suppress(trailingCount)
            resolve(line.count <= maximumStartupLineBytes ? .line(line) : .oversized)
        } else if startupBuffer.count > maximumStartupLineBytes {
            startupBuffer.removeAll(keepingCapacity: false)
            resolve(.oversized)
        }
    }

    func consumeDiagnostic(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        suppress(incoming.count)
    }

    func processExited(status: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard startupResult == nil else { return }
        resolve(.exited(status))
    }

    func waitForStartup(timeout: TimeInterval) async -> KanameLinkGatewayStartupResult {
        await Task.detached { [self] in
            blockingWaitForStartup(timeout: timeout)
        }.value
    }

    private func blockingWaitForStartup(timeout: TimeInterval) -> KanameLinkGatewayStartupResult {
        lock.lock()
        let existing = startupResult
        lock.unlock()
        if let existing { return existing }
        let nanoseconds = Int(timeout * 1_000_000_000)
        guard startupSemaphore.wait(timeout: .now() + .nanoseconds(nanoseconds)) == .success else {
            return .timedOut
        }
        lock.lock()
        defer { lock.unlock() }
        return startupResult ?? .timedOut
    }

    private func resolve(_ result: KanameLinkGatewayStartupResult) {
        guard startupResult == nil else { return }
        startupResult = result
        startupSemaphore.signal()
    }

    private func suppress(_ count: Int) {
        let remaining = maximumSuppressedDiagnosticBytes - suppressedDiagnosticBytes
        guard remaining > 0 else { return }
        suppressedDiagnosticBytes += min(max(0, count), remaining)
    }
}

private final class KanameLinkGatewayExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var exited = false

    func signal() {
        lock.lock()
        exited = true
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> Bool {
        lock.lock()
        let alreadyExited = exited
        lock.unlock()
        return alreadyExited || semaphore.wait(timeout: timeout) == .success
    }
}

private final class KanameLinkOwnedGatewayProcess: @unchecked Sendable {
    let process: Process
    let processIdentifier: Int32
    private let outputPipe: Pipe
    private let errorPipe: Pipe
    private let exitLatch: KanameLinkGatewayExitLatch
    private let terminationLock = NSLock()
    private let pipeLock = NSLock()
    private var pipesClosed = false

    init(
        process: Process,
        outputPipe: Pipe,
        errorPipe: Pipe,
        exitLatch: KanameLinkGatewayExitLatch
    ) {
        self.process = process
        processIdentifier = process.processIdentifier
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.exitLatch = exitLatch
    }

    var isRunning: Bool { process.isRunning }

    var terminationStatusIfAvailable: Int32? {
        process.isRunning ? nil : process.terminationStatus
    }

    func terminateOwnedChild() -> Bool {
        terminationLock.lock()
        defer { terminationLock.unlock() }
        if process.isRunning {
            process.terminate()
        }
        if !exitLatch.wait(timeout: .now() + .seconds(2)), process.isRunning {
            _ = Darwin.kill(processIdentifier, SIGKILL)
            _ = exitLatch.wait(timeout: .now() + .seconds(1))
        }
        return !process.isRunning
    }

    func closePipes() {
        pipeLock.lock()
        defer { pipeLock.unlock() }
        guard !pipesClosed else { return }
        pipesClosed = true
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
    }
}

private final class KanameLinkNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif
