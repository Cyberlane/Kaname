@preconcurrency import Foundation

public struct PersonalCalendarSourceSnapshot: Equatable, Sendable {
    public let accountIdentity: String
    public let externalIdentifier: String
    public let name: String
    public let role: String
    public let isPrimary: Bool
}

public struct PersonalMailThreadSnapshot: Equatable, Sendable {
    public let accountIdentity: String
    public let externalIdentifier: String
    public let flags: String
    public let sender: String
    public let subject: String
    public let snippet: String
    public let dateDescription: String
    public let messageCount: Int
}

public struct GitHubCLIAccessSnapshot: Equatable, Sendable {
    public let login: String
    public let displayName: String
}

public enum PersonalIntegrationError: Error, Equatable, LocalizedError, Sendable {
    case connectorUnavailable(String)
    case connectorFailed(String)
    case outputTooLarge(String)
    case malformedOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .connectorUnavailable(name):
            "\(name) is not installed or executable."
        case let .connectorFailed(name):
            "\(name) could not read its existing local session. Open the connector directly to repair authentication."
        case let .outputTooLarge(name):
            "\(name) returned more data than Kaname accepts in one refresh."
        case let .malformedOutput(name):
            "\(name) returned an unsupported response."
        }
    }
}

public actor PersonalIntegrationService {
    private let workingDirectory: URL
    private let timeout: Duration

    public init(
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        timeout: Duration = .seconds(15)
    ) {
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    public func inspectGitHubAccess(
        executable: String = "gh"
    ) async throws -> GitHubCLIAccessSnapshot {
        let output = try await capture(
            executable: executable,
            arguments: ["api", "user", "--jq", "{login: .login, name: (.name // \"\")}"],
            connector: "GitHub CLI"
        )
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = object["login"] as? String,
              !login.isEmpty else {
            throw PersonalIntegrationError.malformedOutput("GitHub CLI")
        }
        return GitHubCLIAccessSnapshot(
            login: login,
            displayName: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? login
        )
    }

    private func capture(
        executable: String,
        arguments: [String],
        connector: String
    ) async throws -> String {
        let result: CapturedProcessOutput
        do {
            result = try await LocalProcess.capture(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeout: timeout,
                environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals(),
                maximumOutputBytes: 1_048_576
            )
        } catch ProviderConnectivityError.executableNotFound {
            throw PersonalIntegrationError.connectorUnavailable(connector)
        } catch {
            throw PersonalIntegrationError.connectorFailed(connector)
        }
        guard result.exitStatus == 0 else {
            throw PersonalIntegrationError.connectorFailed(connector)
        }
        guard !result.standardOutputWasTruncated, !result.standardErrorWasTruncated else {
            throw PersonalIntegrationError.outputTooLarge(connector)
        }
        return result.standardOutput
    }
}
