import Foundation

/// Interactive shell session for coding-thread terminals on macOS.
/// Uses `/usr/bin/script` to allocate a PTY without Swift `fork()`.
/// Human-only input; providers never drive this shell.
public final class DesktopCodingPTYSession: @unchecked Sendable {
    public let processIdentifier: Int32
    public private(set) var columns: UInt16
    public private(set) var rows: UInt16

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let readQueue = DispatchQueue(label: "com.cyberlane.kaname.coding-pty.read")
    private let writeLock = NSLock()
    private var isClosed = false
    private var onOutput: (@Sendable (Data) -> Void)?

    /// Bundles live process handles for session construction.
    /// Intentional: PTY bootstrap is runtime I/O wiring, not a decode/model field-copy init.
    private struct SessionBootstrap {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let processIdentifier: Int32
        let columns: UInt16
        let rows: UInt16

        var pipePair: (FileHandle, FileHandle) { (input, output) }
        var geometry: (UInt16, UInt16) { (columns, rows) }
    }

    private init(bootstrap: SessionBootstrap) {
        let spawned = bootstrap.process
        let pid = bootstrap.processIdentifier
        let (writeHandle, readHandle) = bootstrap.pipePair
        let (width, height) = bootstrap.geometry
        process = spawned
        processIdentifier = pid
        input = writeHandle
        output = readHandle
        columns = width
        rows = height
    }

    public static func open(
        cwd: URL,
        shell: String = "/bin/zsh",
        columns: UInt16 = 120,
        rows: UInt16 = 32,
        onOutput: @escaping @Sendable (Data) -> Void
    ) throws -> DesktopCodingPTYSession {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", shell, "-l"]
        process.currentDirectoryURL = cwd
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.environment = [
            "TERM": "xterm-256color",
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "HOME": NSHomeDirectory(),
            "COLUMNS": String(columns),
            "LINES": String(rows),
            "PATH": ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "SHELL": shell,
        ]
        do {
            try process.run()
        } catch {
            throw DesktopCodingTerminalError.ptyUnavailable
        }
        let bootstrap = SessionBootstrap(
            process: process,
            input: inputPipe.fileHandleForWriting,
            output: outputPipe.fileHandleForReading,
            processIdentifier: process.processIdentifier,
            columns: columns,
            rows: rows
        )
        let session = DesktopCodingPTYSession(bootstrap: bootstrap)
        session.onOutput = onOutput
        session.startReader()
        return session
    }

    public func write(_ text: String) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { throw DesktopCodingTerminalError.sessionClosed }
        guard let data = text.data(using: .utf8) else {
            throw DesktopCodingTerminalError.writeFailed
        }
        try input.write(contentsOf: data)
    }

    public func resize(columns: UInt16, rows: UInt16) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { throw DesktopCodingTerminalError.sessionClosed }
        self.columns = columns
        self.rows = rows
        // script(1) does not expose master resize; record geometry for metadata only.
    }

    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }

    private func startReader() {
        readQueue.async { [weak self] in
            guard let self else { return }
            while true {
                let data = self.output.availableData
                guard !data.isEmpty else { break }
                self.onOutput?(data)
            }
        }
    }
}

/// Parses `lsof` listen lines into localhost TCP ports for a process.
public enum DesktopCodingTerminalPortScanner {
    public static func listeningLocalPorts(forPID pid: Int32) async throws -> [UInt16] {
        guard pid > 0 else { return [] }
        let result = try await LocalProcess.capture(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(pid)"],
            workingDirectory: URL(fileURLWithPath: "/"),
            timeout: .seconds(5),
            environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals()
        )
        guard result.exitStatus == 0 || result.exitStatus == 1 else {
            throw DesktopCodingTerminalError.portScanFailed
        }
        return parseListeningPorts(from: result.standardOutput)
    }

    public static func parseListeningPorts(from text: String) -> [UInt16] {
        var ports = Set<UInt16>()
        for line in text.split(separator: "\n") {
            guard line.contains("TCP") else { continue }
            guard let range = line.range(of: #":(\d+)\s+\(LISTEN\)"#, options: .regularExpression) else {
                continue
            }
            let token = line[range]
            let digits = token.filter { $0.isNumber }
            if let port = UInt16(digits) { ports.insert(port) }
        }
        return ports.sorted()
    }
}
