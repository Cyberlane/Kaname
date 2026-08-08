@preconcurrency import Foundation

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
}

final class RunningLocalProcess: @unchecked Sendable {
    let process: Process
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle

    init(process: Process, standardInput: FileHandle, standardOutput: FileHandle, standardError: FileHandle) {
        self.process = process
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
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
        environmentOverrides: [String: String] = [:]
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
        process.environment = ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, replacement in replacement }

        do {
            try process.run()
        } catch {
            throw ProviderConnectivityError.processStartFailed("Could not start \(executable): \(error.localizedDescription)")
        }

        return RunningLocalProcess(
            process: process,
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: error.fileHandleForReading
        )
    }

    static func capture(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        timeout: Duration,
        environmentOverrides: [String: String] = [:]
    ) async throws -> CapturedProcessOutput {
        let running = try start(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environmentOverrides: environmentOverrides
        )

        do {
            let status = try await waitForExit(of: running, timeout: timeout, command: executable)
            let output = String(decoding: running.standardOutput.readDataToEndOfFile(), as: UTF8.self)
            let error = String(decoding: running.standardError.readDataToEndOfFile(), as: UTF8.self)
            return CapturedProcessOutput(standardOutput: output, standardError: error, exitStatus: status)
        } catch {
            running.terminate()
            throw error
        }
    }

    private static func waitForExit(of running: RunningLocalProcess, timeout: Duration, command: String) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                running.process.waitUntilExit()
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
