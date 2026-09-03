import Foundation

// Kaname workflow connector host.
//
// The Rust executor runs this program as `describe`, `dispatch`, or
// `reconcile` with one JSON request on stdin and expects one JSON response on
// stdout. Credentials for Gmail and the other connectors live in the desktop
// app's Keychain items, so this host performs no external effect itself: it
// forwards each request over a local Unix socket to the running Kaname app,
// which owns the accounts, and relays the reply. When no app is listening the
// host describes no connectors, so the executor refuses effect graphs instead
// of guessing.

enum HostEnvironment {
    static var home: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return home }
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }

    /// Socket files published by running Kaname apps, newest first.
    static var bridgeSockets: [String] {
        let support = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
        let candidates = names
            .filter { $0 == "Kaname" || $0.hasPrefix("Kaname ") }
            .map { support.appendingPathComponent($0).appendingPathComponent("Runtime/connector-bridge.sock").path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        return candidates.sorted { lhs, rhs in
            let left = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
            let right = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
            return left > right
        }
    }
}

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// One request/response exchange over a Unix domain socket: a single JSON line
/// each way. Returns nil when no app answers.
func exchange(_ line: Data, timeoutSeconds: Int) -> Data? {
    for path in HostEnvironment.bridgeSockets {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { continue }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { continue }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { continue }
        var payload = line
        payload.append(0x0A)
        var sent = 0
        while sent < payload.count {
            let written = payload.withUnsafeBytes { raw -> Int in
                Foundation.write(descriptor, raw.baseAddress!.advanced(by: sent), payload.count - sent)
            }
            guard written > 0 else { return nil }
            sent += written
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while response.count < 8 * 1_048_576 {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(buffer, count: count)
            if response.last == 0x0A { break }
        }
        if !response.isEmpty { return response }
    }
    return nil
}

func forward(mode: String) {
    let request = mode == "describe" ? Data("{}".utf8) : FileHandle.standardInput.readDataToEndOfFile()
    guard let requestObject = (try? JSONSerialization.jsonObject(with: request.isEmpty ? Data("{}".utf8) : request)) as? [String: Any] else {
        emit(mode == "describe" ? ["connectors": [] as [Any]] : ["outcome": "not_sent", "errorCode": "connector.bridge_request_invalid", "summary": "The request was not valid JSON."])
        return
    }
    let envelope: [String: Any] = ["mode": mode, "request": requestObject]
    guard let line = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
          let response = exchange(line, timeoutSeconds: mode == "describe" ? 5 : 120),
          let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
        switch mode {
        case "describe":
            emit(["connectors": [] as [Any]])
        case "dispatch":
            emit(["outcome": "not_sent", "errorCode": "connector.app_unreachable", "summary": "Kaname is not running, so no connector could send this effect."])
        default:
            emit(["outcome": "still_unknown", "errorCode": "connector.app_unreachable", "summary": "Kaname is not running, so the effect could not be reconciled."])
        }
        return
    }
    emit(object)
}

switch CommandLine.arguments.dropFirst().first {
case "describe": forward(mode: "describe")
case "dispatch": forward(mode: "dispatch")
case "reconcile": forward(mode: "reconcile")
default:
    FileHandle.standardError.write(Data("usage: KanameWorkflowConnectorHost describe|dispatch|reconcile < request.json\n".utf8))
    exit(64)
}
