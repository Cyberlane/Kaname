@preconcurrency import Foundation
import Darwin

enum ProviderConnectivityError: Error, LocalizedError, Sendable {
    case executableNotFound(String)
    case processStartFailed(String)
    case processTimedOut(String)
    case processExited(command: String, status: Int32, detail: String?)
    case malformedProtocol(String)
    case unsupportedConfiguration(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(executable):
            "Executable not found: \(executable)."
        case let .processStartFailed(detail), let .processTimedOut(detail),
             let .malformedProtocol(detail), let .unsupportedConfiguration(detail),
             let .network(detail):
            detail
        case let .processExited(command, status, detail):
            ["\(command) exited with status \(status).", detail]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }
}

struct CapturedProcessOutput: Sendable {
    let standardOutput: String
    let standardError: String
    let exitStatus: Int32
    let standardOutputWasTruncated: Bool
    let standardErrorWasTruncated: Bool
}

private final class ProcessExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var finished = false

    func signal() {
        lock.lock()
        finished = true
        lock.unlock()
        semaphore.signal()
    }

    func wait() {
        lock.lock()
        let alreadyFinished = finished
        lock.unlock()
        guard !alreadyFinished else { return }
        semaphore.wait()
    }

    func wait(timeout: DispatchTime) -> Bool {
        lock.lock()
        let alreadyFinished = finished
        lock.unlock()
        return alreadyFinished || semaphore.wait(timeout: timeout) == .success
    }
}

final class RunningLocalProcess: @unchecked Sendable {
    let process: Process
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle
    fileprivate let exitLatch: ProcessExitLatch

    fileprivate init(
        process: Process,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle,
        exitLatch: ProcessExitLatch
    ) {
        self.process = process
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitLatch = exitLatch
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
        // Foundation raises if a Process is deallocated before it has reaped.
        // All Kaname provider shutdowns are fail-closed, so wait for the exact
        // child after asking it to terminate rather than leaving a live child
        // behind or crashing the caller during deallocation.
        if !exitLatch.wait(timeout: .now() + 2), process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            exitLatch.wait()
        }
    }

    func waitForExit() {
        exitLatch.wait()
    }
}

enum LocalProcess {
    static func resolveExecutable(named requested: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let expanded = (requested as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded)
                ? URL(fileURLWithPath: expanded)
                : nil
        }

        let searchPath = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for directory in searchPath {
            let candidate = URL(fileURLWithPath: directory).appending(path: expanded)
            if FileManager.default.isExecutableFile(atPath: candidate.path()) {
                return candidate
            }
        }
        return nil
    }

    static func start(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environmentOverrides: [String: String] = [:],
        environmentRemovals: Set<String> = []
    ) throws -> RunningLocalProcess {
        guard let executableURL = resolveExecutable(named: executable) else {
            throw ProviderConnectivityError.executableNotFound(executable)
        }

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        var environment = ProcessInfo.processInfo.environment
            .merging(environmentOverrides) { _, replacement in replacement }
        for name in environmentRemovals {
            environment.removeValue(forKey: name)
        }
        process.environment = environment
        let exitLatch = ProcessExitLatch()
        process.terminationHandler = { _ in
            exitLatch.signal()
        }

        do {
            try process.run()
        } catch {
            throw ProviderConnectivityError.processStartFailed("Could not start \(executable): \(error.localizedDescription)")
        }

        return RunningLocalProcess(
            process: process,
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: error.fileHandleForReading,
            exitLatch: exitLatch
        )
    }

    static func capture(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        timeout: Duration,
        environmentOverrides: [String: String] = [:],
        environmentRemovals: Set<String> = [],
        maximumOutputBytes: Int = 1_048_576
    ) async throws -> CapturedProcessOutput {
        let running = try start(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environmentOverrides: environmentOverrides,
            environmentRemovals: environmentRemovals
        )

        let outputTask = _Concurrency.Task.detached {
            readBounded(running.standardOutput, maximumBytes: maximumOutputBytes)
        }
        let errorTask = _Concurrency.Task.detached {
            readBounded(running.standardError, maximumBytes: maximumOutputBytes)
        }

        do {
            let status = try await waitForExit(of: running, timeout: timeout, command: executable)
            let output = await outputTask.value
            let error = await errorTask.value
            return CapturedProcessOutput(
                standardOutput: String(decoding: output.data, as: UTF8.self),
                standardError: String(decoding: error.data, as: UTF8.self),
                exitStatus: status,
                standardOutputWasTruncated: output.truncated,
                standardErrorWasTruncated: error.truncated
            )
        } catch {
            running.terminate()
            _ = await outputTask.value
            _ = await errorTask.value
            throw error
        }
    }

    private struct BoundedData: Sendable {
        let data: Data
        let truncated: Bool
    }

    private static func readBounded(_ file: FileHandle, maximumBytes: Int) -> BoundedData {
        let boundedMaximum = max(1, maximumBytes)
        var retained = Data()
        var truncated = false
        while true {
            let chunk = file.availableData
            guard !chunk.isEmpty else { break }
            let remaining = boundedMaximum - retained.count
            if remaining > 0 {
                retained.append(chunk.prefix(remaining))
            }
            if chunk.count > max(0, remaining) {
                truncated = true
            }
        }
        return BoundedData(data: retained, truncated: truncated)
    }

    private static func waitForExit(of running: RunningLocalProcess, timeout: Duration, command: String) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                running.exitLatch.wait()
                return running.process.terminationStatus
            }
            group.addTask {
                try await _Concurrency.Task.sleep(for: timeout)
                running.terminate()
                throw ProviderConnectivityError.processTimedOut("Timed out while checking \(command).")
            }

            guard let first = try await group.next() else {
                throw ProviderConnectivityError.processTimedOut("Timed out while checking \(command).")
            }
            group.cancelAll()
            return first
        }
    }
}
