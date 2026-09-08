#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import KanameLinkHost

@Suite(.serialized)
struct KanameLinkGatewayRuntimeTests {
    @Test
    func launchesExactServeContractPassesHealthAndSuppliesExactAdminArguments() async throws {
        let fixture = try GatewayRuntimeFixture(mode: "healthy")
        let runtime = try KanameLinkGatewayRuntime(
            executableURL: fixture.executableURL,
            stateRootURL: fixture.stateRootURL,
            configuration: fixture.configuration
        )
        do {
            let status = try await runtime.start()
            #expect(status.state == .running)
            #expect(status.bindAddress == fixture.bindAddress)
            #expect(status.healthVerified)
            #expect(status.ownedProcessIdentifier != nil)

            let serveArguments = try fixture.recordedArguments(named: "serve-arguments.json")
            #expect(serveArguments == [
                "serve",
                "--state-root", fixture.stateRootURL.path,
                "--bind", fixture.bindAddress,
            ])

            let admin = try await runtime.makeAdminRunner()
            let response = try await admin.execute(
                KanameLinkAdminRequest.hostSnapshot(requestID: "runtime-request-1")
            )
            let responseObject = try #require(
                JSONSerialization.jsonObject(with: response) as? [String: Any]
            )
            #expect(responseObject["requestID"] as? String == "runtime-request-1")
            #expect(responseObject["ok"] as? Bool == true)
            let adminArguments = try fixture.recordedArguments(named: "admin-arguments.json")
            #expect(adminArguments == [
                "admin",
                "--state-root", fixture.stateRootURL.path,
            ])

            let processIdentifier = try #require(status.ownedProcessIdentifier)
            try await runtime.stop()
            #expect((await runtime.status()).state == .stopped)
            #expect(Darwin.kill(processIdentifier, 0) != 0)
        } catch {
            try? await runtime.stop()
            throw error
        }
    }

    @Test
    func occupiedPortFailsBeforeLaunchAndDoesNotTerminateExistingOwnedChild() async throws {
        let firstFixture = try GatewayRuntimeFixture(mode: "healthy")
        let first = try KanameLinkGatewayRuntime(
            executableURL: firstFixture.executableURL,
            stateRootURL: firstFixture.stateRootURL,
            configuration: firstFixture.configuration
        )
        let secondFixture = try GatewayRuntimeFixture(
            mode: "healthy",
            bindAddress: firstFixture.bindAddress
        )
        let second = try KanameLinkGatewayRuntime(
            executableURL: secondFixture.executableURL,
            stateRootURL: secondFixture.stateRootURL,
            configuration: secondFixture.configuration
        )
        do {
            let firstStatus = try await first.start()
            let firstPID = try #require(firstStatus.ownedProcessIdentifier)
            await #expect(throws: KanameLinkGatewayRuntimeFailure.portOccupied) {
                try await second.start()
            }
            #expect((await second.status()).state == .failed(.portOccupied))
            #expect(!FileManager.default.fileExists(
                atPath: secondFixture.stateRootURL.appending(path: "serve-arguments.json").path
            ))
            let stillRunning = await first.status()
            #expect(stillRunning.state == .running)
            #expect(stillRunning.ownedProcessIdentifier == firstPID)
            #expect(Darwin.kill(firstPID, 0) == 0)
            try await first.stop()
        } catch {
            try? await second.stop()
            try? await first.stop()
            throw error
        }
    }

    @Test
    func rejectsMismatchedStartupReceiptAndTerminatesOnlySpawnedChild() async throws {
        let fixture = try GatewayRuntimeFixture(mode: "wrong-startup")
        let runtime = try KanameLinkGatewayRuntime(
            executableURL: fixture.executableURL,
            stateRootURL: fixture.stateRootURL,
            configuration: fixture.configuration
        )

        await #expect(throws: KanameLinkGatewayRuntimeFailure.startupMismatch) {
            try await runtime.start()
        }
        let status = await runtime.status()
        #expect(status.state == .failed(.startupMismatch))
        #expect(status.ownedProcessIdentifier == nil)
        #expect(!status.healthVerified)
    }

    @Test
    func suppressesUntrustedDiagnosticsWhenChildExitsBeforeStartup() async throws {
        let fixture = try GatewayRuntimeFixture(mode: "exit-before-startup")
        let runtime = try KanameLinkGatewayRuntime(
            executableURL: fixture.executableURL,
            stateRootURL: fixture.stateRootURL,
            configuration: fixture.configuration
        )

        do {
            _ = try await runtime.start()
            Issue.record("Expected the controlled child to exit")
        } catch let failure as KanameLinkGatewayRuntimeFailure {
            #expect(failure == .childExited(status: 17))
            #expect(!failure.localizedDescription.contains("fixture-secret"))
        }
        let status = await runtime.status()
        #expect(status.state == .failed(.childExited(status: 17)))
        #expect(status.ownedProcessIdentifier == nil)
    }

    @Test
    func healthFailureTerminatesChildAndNeverReportsRunning() async throws {
        let fixture = try GatewayRuntimeFixture(mode: "unhealthy")
        let runtime = try KanameLinkGatewayRuntime(
            executableURL: fixture.executableURL,
            stateRootURL: fixture.stateRootURL,
            configuration: fixture.configuration
        )

        await #expect(throws: KanameLinkGatewayRuntimeFailure.healthTimedOut) {
            try await runtime.start()
        }
        let status = await runtime.status()
        #expect(status.state == .failed(.healthTimedOut))
        #expect(status.ownedProcessIdentifier == nil)
        #expect(!status.healthVerified)
    }

    @Test
    func unexpectedExitAfterHealthTransitionsRuntimeToFailed() async throws {
        let fixture = try GatewayRuntimeFixture(mode: "exit-after-health")
        let runtime = try KanameLinkGatewayRuntime(
            executableURL: fixture.executableURL,
            stateRootURL: fixture.stateRootURL,
            configuration: fixture.configuration
        )
        do {
            _ = try await runtime.start()
            let failed = await waitForFailure(runtime)
            #expect(failed.state == .failed(.childExited(status: 23)))
            #expect(failed.ownedProcessIdentifier == nil)
            #expect(!failed.healthVerified)
        } catch {
            try? await runtime.stop()
            throw error
        }
    }

    private func waitForFailure(
        _ runtime: KanameLinkGatewayRuntime
    ) async -> KanameLinkGatewayRuntimeStatus {
        for _ in 0..<40 {
            let status = await runtime.status()
            if case .failed = status.state { return status }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await runtime.status()
    }
}

private final class GatewayRuntimeFixture {
    let rootURL: URL
    let executableURL: URL
    let stateRootURL: URL
    let configuration: KanameLinkGatewayRuntimeConfiguration
    let bindAddress: String

    init(mode: String, bindAddress: String? = nil) throws {
        let selectedPort: UInt16
        if let bindAddress {
            selectedPort = try Self.port(from: bindAddress)
        } else {
            selectedPort = try Self.reserveLoopbackPort()
        }
        self.bindAddress = bindAddress ?? "127.0.0.1:\(selectedPort)"
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "kaname-link-runtime-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bundleURL = rootURL.appending(path: "Bundle", directoryHint: .isDirectory)
        stateRootURL = rootURL.appending(path: "Link", directoryHint: .isDirectory)
        executableURL = bundleURL.appending(path: "kaname-link-gateway")
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: stateRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(mode.utf8).write(to: stateRootURL.appending(path: "fixture-mode"), options: .atomic)
        try Data(Self.executableSource.utf8).write(to: executableURL, options: .atomic)
        guard chmod(executableURL.path, S_IRWXU) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        configuration = try KanameLinkGatewayRuntimeConfiguration(
            startupTimeout: 2,
            healthRequestTimeout: 0.1,
            maximumStartupLineBytes: 1_024,
            maximumSuppressedDiagnosticBytes: 512,
            bindAddress: self.bindAddress
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func recordedArguments(named name: String) throws -> [String] {
        let data = try Data(contentsOf: stateRootURL.appending(path: name))
        return try JSONDecoder().decode([String].self, from: data)
    }

    private static func port(from bindAddress: String) throws -> UInt16 {
        guard let port = bindAddress.split(separator: ":").last.flatMap({ UInt16($0) }), port > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return port
    }

    private static func reserveLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0 else { throw POSIXError(.EIO) }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        let port = UInt16(bigEndian: assigned.sin_port)
        guard port > 0 else { throw POSIXError(.EIO) }
        return port
    }

    private static let executableSource = #"""
#!/usr/bin/python3
import http.server
import json
import os
import signal
import sys
import threading
import time

arguments = sys.argv[1:]
if len(arguments) < 3 or "--state-root" not in arguments:
    sys.exit(91)
state_root = arguments[arguments.index("--state-root") + 1]
os.makedirs(state_root, mode=0o700, exist_ok=True)

if arguments[0] == "admin":
    with open(os.path.join(state_root, "admin-arguments.json"), "w", encoding="utf-8") as handle:
        json.dump(arguments, handle, separators=(",", ":"))
    request = json.load(sys.stdin)
    print(json.dumps({
        "schemaVersion": 1,
        "requestID": request.get("requestID", "invalid"),
        "ok": True,
        "result": {}
    }, separators=(",", ":")), flush=True)
    sys.exit(0)

if "--bind" not in arguments:
    sys.exit(91)
bind_address = arguments[arguments.index("--bind") + 1]
host, port_text = bind_address.rsplit(":", 1)
port = int(port_text)

with open(os.path.join(state_root, "serve-arguments.json"), "w", encoding="utf-8") as handle:
    json.dump(arguments, handle, separators=(",", ":"))
with open(os.path.join(state_root, "fixture-mode"), "r", encoding="utf-8") as handle:
    mode = handle.read().strip()

if mode == "exit-before-startup":
    sys.stderr.write("fixture-secret:" + ("x" * 65536))
    sys.stderr.flush()
    sys.exit(17)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_response(404)
            self.end_headers()
            return
        if mode == "unhealthy":
            self.send_response(500)
            self.end_headers()
            return
        self.send_response(204)
        self.end_headers()
        if mode == "exit-after-health":
            def exit_later():
                time.sleep(0.25)
                os._exit(23)
            threading.Thread(target=exit_later, daemon=True).start()

    def log_message(self, format, *args):
        return

server = http.server.HTTPServer((host, port), Handler)
startup_address = f"{host}:{port + 1}" if mode == "wrong-startup" else bind_address
print(json.dumps({
    "schemaVersion": 1,
    "requestID": "startup",
    "ok": True,
    "result": {"listeningAddress": startup_address}
}, separators=(",", ":")), flush=True)
server.serve_forever()
"""#
}
#endif
