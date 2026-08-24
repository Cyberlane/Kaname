import Foundation

enum LinkClientCoreError: Error, Equatable {
    case helperUnavailable
    case launchFailed
    case timedOut
    case requestTooLarge
    case responseTooLarge
    case invalidResponse
    case rejected(String)
}

struct LinkInvitationArtifact: Codable, Sendable {
    let schemaVersion: Int
    let inviteId: String
    let spaceId: String
    let spaceName: String
    let gatewayUrl: String
    let hostStaticPublicKey: String
    let inviteSecret: String
    let expiresAtUnixMillis: Int64
}

private enum LinkClientRPCPayload: Encodable, Sendable {
    case empty
    case strings([String: String])
    case enrollment(invite: LinkInvitationArtifact, displayName: String)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .empty:
            try EmptyPayload().encode(to: encoder)
        case let .strings(fields):
            try fields.encode(to: encoder)
        case let .enrollment(invite, displayName):
            try EnrollmentPayload(invite: invite, displayName: displayName).encode(to: encoder)
        }
    }

    private struct EmptyPayload: Encodable {}
    private struct EnrollmentPayload: Encodable {
        let invite: LinkInvitationArtifact
        let displayName: String
    }
}

struct LinkClientRPCRequest: Encodable, Sendable {
    let schemaVersion: Int
    let requestID: String
    let operation: String
    private let payload: LinkClientRPCPayload

    init(
        operation: String,
        payload: [String: String] = [:],
        requestID: String = UUID().uuidString.lowercased()
    ) {
        self.schemaVersion = 1
        self.requestID = requestID
        self.operation = operation
        self.payload = payload.isEmpty ? .empty : .strings(payload)
    }

    static func enroll(
        invite: LinkInvitationArtifact,
        displayName: String,
        requestID: String = UUID().uuidString.lowercased()
    ) -> LinkClientRPCRequest {
        LinkClientRPCRequest(
            requestID: requestID,
            operation: "enroll",
            payload: .enrollment(invite: invite, displayName: displayName)
        )
    }

    private init(
        requestID: String,
        operation: String,
        payload: LinkClientRPCPayload
    ) {
        schemaVersion = 1
        self.requestID = requestID
        self.operation = operation
        self.payload = payload
    }
}

struct LinkClientRPCResponse: Codable, Sendable {
    let schemaVersion: Int
    let requestID: String
    let ok: Bool
    let errorCode: String?
    let snapshot: LinkClientSnapshot?
}

/// Runs the portable Link core as a one-request process. Secrets and message
/// bodies travel over stdin, never argv. The helper must emit one bounded JSON
/// response on stdout; stderr is diagnostic-only and is never shown verbatim.
actor LinkClientCoreRunner {
    static let maximumRequestBytes = 64 * 1_024
    static let maximumResponseBytes = 256 * 1_024
    static let maximumErrorBytes = 16 * 1_024

    private let executableURL: URL?

    init(executableURL: URL? = LinkClientCoreRunner.defaultExecutableURL()) {
        self.executableURL = executableURL
    }

    func request(
        _ request: LinkClientRPCRequest,
        timeout: Duration = .seconds(10)
    ) async throws -> LinkClientRPCResponse {
        guard let executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LinkClientCoreError.helperUnavailable
        }

        let input = try JSONEncoder.link.encode(request)
        guard input.count <= Self.maximumRequestBytes else {
            throw LinkClientCoreError.requestTooLarge
        }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = ["rpc"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw LinkClientCoreError.launchFailed
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()

        let responseData = try await withThrowingTaskGroup(of: LinkClientPipeResult.self) { group in
            group.addTask {
                .standardOutput(try Self.readBounded(
                    stdout.fileHandleForReading,
                    maximumBytes: Self.maximumResponseBytes,
                    overflow: .responseTooLarge
                ))
            }
            group.addTask {
                _ = try Self.readBounded(
                    stderr.fileHandleForReading,
                    maximumBytes: Self.maximumErrorBytes,
                    overflow: .invalidResponse
                )
                return .standardErrorDrained
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LinkClientCoreError.timedOut
            }
            defer {
                group.cancelAll()
                if process.isRunning { process.terminate() }
            }
            while let result = try await group.next() {
                if case let .standardOutput(data) = result {
                    return data
                }
            }
            throw LinkClientCoreError.invalidResponse
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0,
              !responseData.isEmpty,
              let response = try? JSONDecoder.link.decode(
                LinkClientRPCResponse.self,
                from: responseData
              ),
              response.schemaVersion == 1,
              response.requestID == request.requestID else {
            throw LinkClientCoreError.invalidResponse
        }
        guard response.ok else {
            throw LinkClientCoreError.rejected(response.errorCode ?? "request_rejected")
        }
        return response
    }

    private static func readBounded(
        _ handle: FileHandle,
        maximumBytes: Int,
        overflow: LinkClientCoreError
    ) throws -> Data {
        var result = Data()
        while true {
            let remaining = maximumBytes - result.count
            guard let chunk = try handle.read(upToCount: min(16 * 1_024, remaining + 1)),
                  !chunk.isEmpty else {
                return result
            }
            result.append(chunk)
            if result.count > maximumBytes {
                throw overflow
            }
        }
    }

    private static func defaultExecutableURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["KANAME_LINK_CLIENT_CORE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return Bundle.main.url(forResource: "kaname-link-client", withExtension: nil)
    }
}

private enum LinkClientPipeResult: Sendable {
    case standardOutput(Data)
    case standardErrorDrained
}

private extension JSONEncoder {
    static var link: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static let link = JSONDecoder()
}
