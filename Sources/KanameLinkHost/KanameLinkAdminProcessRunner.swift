import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct KanameLinkProcessRunnerConfiguration: Equatable, Sendable {
    public static let standard = try! KanameLinkProcessRunnerConfiguration()

    public let timeout: TimeInterval
    public let maximumInputBytes: Int
    public let maximumOutputBytes: Int
    public let maximumErrorBytes: Int

    public init(
        timeout: TimeInterval = 4,
        maximumInputBytes: Int = 64 * 1024,
        maximumOutputBytes: Int = 256 * 1024,
        maximumErrorBytes: Int = 16 * 1024
    ) throws {
        guard timeout >= 0.05, timeout <= 10,
              maximumInputBytes >= 1, maximumInputBytes <= 256 * 1024,
              maximumOutputBytes >= 1, maximumOutputBytes <= 1024 * 1024,
              maximumErrorBytes >= 1, maximumErrorBytes <= 64 * 1024 else {
            throw KanameLinkProcessRunnerError.invalidConfiguration
        }
        self.timeout = timeout
        self.maximumInputBytes = maximumInputBytes
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumErrorBytes = maximumErrorBytes
    }
}

public enum KanameLinkProcessRunnerError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case invalidArguments
    case executableUnavailable(String)
    case requestTooLarge(actual: Int, limit: Int)
    case standardOutputTooLarge(limit: Int)
    case standardErrorTooLarge(limit: Int)
    case launchFailed(String)
    case timedOut(milliseconds: Int)
    case nonZeroExit(status: Int32, standardError: String)
    case emptyResponse
    case malformedResponse
    case responseCorrelationMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The Link gateway process limits are invalid."
        case .invalidArguments:
            "The Link gateway process arguments are invalid."
        case let .executableUnavailable(path):
            "The bundled Link gateway executable is unavailable at \(path)."
        case let .requestTooLarge(actual, limit):
            "The Link gateway request was \(actual) bytes, exceeding the \(limit)-byte limit."
        case let .standardOutputTooLarge(limit):
            "The Link gateway response exceeded the \(limit)-byte limit."
        case let .standardErrorTooLarge(limit):
            "The Link gateway error output exceeded the \(limit)-byte limit."
        case let .launchFailed(message):
            "The Link gateway process could not start: \(message)"
        case let .timedOut(milliseconds):
            "The Link gateway process exceeded its \(milliseconds)-millisecond deadline."
        case let .nonZeroExit(status, standardError):
            standardError.isEmpty
                ? "The Link gateway process exited with status \(status)."
                : "The Link gateway process exited with status \(status): \(standardError)"
        case .emptyResponse:
            "The Link gateway process returned no JSON response."
        case .malformedResponse:
            "The Link gateway process returned malformed JSON."
        case .responseCorrelationMismatch:
            "The Link gateway response did not match the request."
        }
    }
}

/// Runs one fixed gateway executable/argument contract without a shell. The
/// app-lifetime runtime supplies canonical `admin --state-root <Link dir>`
/// arguments; individual requests cannot alter them.
public actor KanameLinkAdminProcessRunner: KanameLinkAdminCommandRunning {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let configuration: KanameLinkProcessRunnerConfiguration

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        configuration: KanameLinkProcessRunnerConfiguration = .standard
    ) throws {
        guard arguments.count <= 8,
              arguments.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else {
            throw KanameLinkProcessRunnerError.invalidArguments
        }
        guard environment.count <= 16,
              environment.allSatisfy({ key, value in
                  key.hasPrefix("KANAME_LINK_")
                      && key.utf8.count <= 128
                      && !value.contains("\0")
                      && value.utf8.count <= 4 * 1_024
              }) else {
            throw KanameLinkProcessRunnerError.invalidArguments
        }
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.configuration = configuration
    }

    public func execute(_ request: KanameLinkAdminRequest) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var requestData = try encoder.encode(request)
        requestData.append(0x0A)
        guard requestData.count <= configuration.maximumInputBytes else {
            throw KanameLinkProcessRunnerError.requestTooLarge(
                actual: requestData.count,
                limit: configuration.maximumInputBytes
            )
        }

        let responseData = try runProcess(requestData: requestData)
        guard !responseData.isEmpty else {
            throw KanameLinkProcessRunnerError.emptyResponse
        }
        return responseData
    }

    private func runProcess(requestData: Data) throws -> Data {
        let path = executableURL.standardizedFileURL.path
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else {
            throw KanameLinkProcessRunnerError.executableUnavailable(path)
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = KanameLinkBoundedPipeCollector(limit: configuration.maximumOutputBytes)
        let errorCollector = KanameLinkBoundedPipeCollector(limit: configuration.maximumErrorBytes)
        let termination = DispatchSemaphore(value: 0)

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment.merging([
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]) { configured, _ in configured }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in termination.signal() }
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            outputCollector.consume(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.consume(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            throw KanameLinkProcessRunnerError.launchFailed(error.localizedDescription)
        }

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: requestData)
            try inputPipe.fileHandleForWriting.close()
        } catch {
            terminate(process, termination: termination)
            finishReading(outputPipe, collector: outputCollector, drain: !process.isRunning)
            finishReading(errorPipe, collector: errorCollector, drain: !process.isRunning)
            throw KanameLinkProcessRunnerError.launchFailed("stdin write failed")
        }

        let timeoutNanoseconds = Int(configuration.timeout * 1_000_000_000)
        let waitResult = termination.wait(
            timeout: .now() + .nanoseconds(timeoutNanoseconds)
        )
        let didTimeOut = waitResult == .timedOut
        if didTimeOut {
            terminate(process, termination: termination)
        }

        finishReading(outputPipe, collector: outputCollector, drain: !process.isRunning)
        finishReading(errorPipe, collector: errorCollector, drain: !process.isRunning)
        let output = outputCollector.snapshot()
        let errorOutput = errorCollector.snapshot()

        if output.exceededLimit {
            throw KanameLinkProcessRunnerError.standardOutputTooLarge(
                limit: configuration.maximumOutputBytes
            )
        }
        if errorOutput.exceededLimit {
            throw KanameLinkProcessRunnerError.standardErrorTooLarge(
                limit: configuration.maximumErrorBytes
            )
        }
        if didTimeOut {
            throw KanameLinkProcessRunnerError.timedOut(
                milliseconds: Int(configuration.timeout * 1_000)
            )
        }
        guard process.terminationStatus == 0 else {
            throw KanameLinkProcessRunnerError.nonZeroExit(
                status: process.terminationStatus,
                standardError: String(decoding: errorOutput.data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output.data
    }

    private func finishReading(
        _ pipe: Pipe,
        collector: KanameLinkBoundedPipeCollector,
        drain: Bool = true
    ) {
        pipe.fileHandleForReading.readabilityHandler = nil
        if drain {
            let remainder = pipe.fileHandleForReading.readDataToEndOfFile()
            collector.consume(remainder)
        }
        try? pipe.fileHandleForReading.close()
    }

    private func terminate(_ process: Process, termination: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if termination.wait(timeout: .now() + .milliseconds(250)) == .timedOut,
           process.isRunning {
#if canImport(Darwin) || canImport(Glibc)
            _ = kill(process.processIdentifier, SIGKILL)
#endif
            _ = termination.wait(timeout: .now() + .seconds(1))
        }
    }
}

private final class KanameLinkBoundedPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var exceededLimit = false

    init(limit: Int) {
        self.limit = limit
    }

    func consume(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if incoming.count > remaining {
            data.append(incoming.prefix(remaining))
            exceededLimit = true
        } else {
            data.append(incoming)
        }
    }

    func snapshot() -> (data: Data, exceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, exceededLimit)
    }
}
