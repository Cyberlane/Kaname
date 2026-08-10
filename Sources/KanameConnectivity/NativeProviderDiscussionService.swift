import Foundation

public enum NativeProviderDiscussionDriver: String, CaseIterable, Equatable, Sendable {
    case claude
    case openCode

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openCode: "OpenCode"
        }
    }
}

public struct NativeProviderDiscussionResult: Equatable, Sendable {
    public let driver: NativeProviderDiscussionDriver
    public let text: String
    public let sessionIdentifier: String?
}

public enum NativeProviderDiscussionError: Error, Equatable, LocalizedError, Sendable {
    case invalidPrompt
    case invalidWorkspace
    case unavailable(String)
    case failed(String)
    case malformedOutput(String)
    case outputTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPrompt: "Enter a prompt of 100,000 bytes or fewer."
        case .invalidWorkspace: "Choose an existing workspace directory."
        case let .unavailable(provider): "\(provider) is not installed or executable."
        case let .failed(provider): "\(provider) stopped without producing a discussion result. Repair its session in the native CLI, then retry."
        case let .malformedOutput(provider): "\(provider) returned an unsupported response."
        case let .outputTooLarge(provider): "\(provider) returned more than Kaname's 4 MiB discussion limit."
        }
    }
}

public actor NativeProviderDiscussionService {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(600)) {
        self.timeout = timeout
    }

    public func run(
        driver: NativeProviderDiscussionDriver,
        prompt: String,
        workspace: URL,
        executable: String? = nil
    ) async throws -> NativeProviderDiscussionResult {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty, cleanPrompt.utf8.count <= 100_000 else {
            throw NativeProviderDiscussionError.invalidPrompt
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NativeProviderDiscussionError.invalidWorkspace
        }

        let command = executable ?? (driver == .claude ? "claude" : "opencode")
        let arguments: [String]
        switch driver {
        case .claude:
            arguments = [
                "--print",
                "--output-format", "json",
                "--permission-mode", "plan",
                "--no-session-persistence",
                "--max-budget-usd", "2",
                cleanPrompt,
            ]
        case .openCode:
            arguments = [
                "run",
                "--format", "json",
                "--agent", "plan",
                "--dir", workspace.path,
                cleanPrompt,
            ]
        }

        let output: CapturedProcessOutput
        do {
            output = try await LocalProcess.capture(
                executable: command,
                arguments: arguments,
                workingDirectory: workspace,
                timeout: timeout,
                environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals(),
                maximumOutputBytes: 4_194_304
            )
        } catch ProviderConnectivityError.executableNotFound {
            throw NativeProviderDiscussionError.unavailable(driver.displayName)
        } catch {
            throw NativeProviderDiscussionError.failed(driver.displayName)
        }
        guard !output.standardOutputWasTruncated, !output.standardErrorWasTruncated else {
            throw NativeProviderDiscussionError.outputTooLarge(driver.displayName)
        }
        guard output.exitStatus == 0 else {
            throw NativeProviderDiscussionError.failed(driver.displayName)
        }
        return try Self.parse(driver: driver, output: output.standardOutput)
    }

    static func parse(
        driver: NativeProviderDiscussionDriver,
        output: String
    ) throws -> NativeProviderDiscussionResult {
        switch driver {
        case .claude:
            return try parseClaude(output)
        case .openCode:
            return try parseOpenCode(output)
        }
    }

    private static func parseClaude(_ output: String) throws -> NativeProviderDiscussionResult {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? String,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeProviderDiscussionError.malformedOutput("Claude")
        }
        return NativeProviderDiscussionResult(
            driver: .claude,
            text: result,
            sessionIdentifier: object["session_id"] as? String
        )
    }

    private static func parseOpenCode(_ output: String) throws -> NativeProviderDiscussionResult {
        var textParts: [String] = []
        var sessionIdentifier: String?
        for line in output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            collectText(from: object, into: &textParts)
            if sessionIdentifier == nil, let dictionary = object as? [String: Any] {
                sessionIdentifier = (dictionary["sessionID"] as? String)
                    ?? (dictionary["session_id"] as? String)
            }
        }
        let result = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw NativeProviderDiscussionError.malformedOutput("OpenCode")
        }
        return NativeProviderDiscussionResult(
            driver: .openCode,
            text: result,
            sessionIdentifier: sessionIdentifier
        )
    }

    private static func collectText(from value: Any, into results: inout [String]) {
        if let dictionary = value as? [String: Any] {
            if let text = dictionary["text"] as? String, !text.isEmpty {
                results.append(text)
            }
            for (key, child) in dictionary where key != "text" {
                collectText(from: child, into: &results)
            }
        } else if let array = value as? [Any] {
            for child in array { collectText(from: child, into: &results) }
        }
    }
}
