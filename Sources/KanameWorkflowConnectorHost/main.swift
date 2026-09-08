import Foundation

// Kaname workflow connector host.
//
// The Rust executor runs this program as `describe`, `dispatch`, or
// `reconcile` with one JSON request on stdin and expects one JSON response on
// stdout. Credentials for Gmail and the other connectors live in the desktop
// app's Keychain items, so this host performs no external effect itself: it
// forwards each request over the one channel-specific local Unix socket named
// by KANAME_WORKFLOW_CONNECTOR_SOCKET to the running Kaname app, which owns the
// accounts, and relays the reply. The host never discovers or guesses among
// other Kaname channels. When the configured socket is unavailable the host
// describes no connectors, so the executor refuses effect graphs instead of
// guessing.

enum HostEnvironment {
    /// The parent process supplies the exact socket for its app channel. An
    /// absent, relative, malformed, or overlong value fails closed rather than
    /// falling back to another installed Kaname channel.
    static var bridgeSocket: String? {
        guard let raw = ProcessInfo.processInfo.environment["KANAME_WORKFLOW_CONNECTOR_SOCKET"],
              !raw.isEmpty,
              raw.hasPrefix("/"),
              !raw.contains("\0"),
              !raw.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
            return nil
        }
        let path = URL(fileURLWithPath: raw).standardizedFileURL.path
        guard path.hasPrefix("/"),
              path.utf8.count < MemoryLayout<sockaddr_un>.size else { return nil }
        return path
    }
}

enum BridgeExchangeResult {
    case response(Data)
    case unavailable
    /// The request was partially or fully written, but no definitive reply
    /// arrived. A workflow effect must be reconciled before retrying.
    case outcomeUnknown
}

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// One request/response exchange over the configured Unix domain socket: a
/// single JSON line each way. A connected socket with bytes written but no
/// response is outcome-unknown; it must never be reported as not sent.
func exchange(_ line: Data, timeoutSeconds: Int) -> BridgeExchangeResult {
    guard let path = HostEnvironment.bridgeSocket else { return .unavailable }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return .unavailable }
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return .unavailable }
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
    guard connected == 0 else { return .unavailable }
    var payload = line
    payload.append(0x0A)
    var sent = 0
    while sent < payload.count {
        let written = payload.withUnsafeBytes { raw -> Int in
            Foundation.write(descriptor, raw.baseAddress!.advanced(by: sent), payload.count - sent)
        }
        guard written > 0 else { return sent == 0 ? .unavailable : .outcomeUnknown }
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
    return response.isEmpty ? .outcomeUnknown : .response(response)
}

func forward(mode: String) {
    let request = mode == "describe" ? Data("{}".utf8) : FileHandle.standardInput.readDataToEndOfFile()
    guard let requestObject = (try? JSONSerialization.jsonObject(with: request.isEmpty ? Data("{}".utf8) : request)) as? [String: Any] else {
        emit(mode == "describe" ? ["connectors": [] as [Any]] : ["outcome": "not_sent", "errorCode": "connector.bridge_request_invalid", "summary": "The request was not valid JSON."])
        return
    }
    let envelope: [String: Any] = ["mode": mode, "request": requestObject]
    guard let line = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else {
        emit(mode == "describe"
            ? ["connectors": [] as [Any]]
            : ["outcome": mode == "dispatch" ? "not_sent" : "still_unknown", "errorCode": "connector.bridge_request_encoding_failed", "summary": "The connector request could not be encoded safely."])
        return
    }
    switch exchange(line, timeoutSeconds: mode == "describe" ? 5 : 120) {
    case .response(let response):
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            emit(mode == "describe"
                ? ["connectors": [] as [Any]]
                : ["outcome": mode == "dispatch" ? "outcome_unknown" : "still_unknown", "errorCode": "connector.transport_unknown", "summary": "The connector bridge returned an invalid response; reconcile before retrying any effect."])
            return
        }
        emit(object)
    case .unavailable:
        switch mode {
        case "describe":
            emit(["connectors": [] as [Any]])
        case "dispatch":
            emit(["outcome": "not_sent", "errorCode": "connector.bridge_unavailable", "summary": "The configured Kaname connector bridge is unavailable; no connector request was written."])
        default:
            emit(["outcome": "still_unknown", "errorCode": "connector.bridge_unavailable", "summary": "The configured Kaname connector bridge is unavailable, so the effect could not be reconciled."])
        }
    case .outcomeUnknown:
        switch mode {
        case "describe":
            emit(["connectors": [] as [Any]])
        case "dispatch":
            emit(["outcome": "outcome_unknown", "errorCode": "connector.transport_unknown", "summary": "The connector request may have reached Kaname, but no definitive response arrived; reconcile before retrying."])
        default:
            emit(["outcome": "still_unknown", "errorCode": "connector.transport_unknown", "summary": "The connector request may have reached Kaname, but no definitive response arrived; reconcile before retrying."])
        }
    }
}

switch CommandLine.arguments.dropFirst().first {
case "describe": forward(mode: "describe")
case "dispatch": forward(mode: "dispatch")
case "reconcile": forward(mode: "reconcile")
default:
    FileHandle.standardError.write(Data("usage: KanameWorkflowConnectorHost describe|dispatch|reconcile < request.json\n".utf8))
    exit(64)
}
