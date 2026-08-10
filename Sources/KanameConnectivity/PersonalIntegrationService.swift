@preconcurrency import Foundation

public struct ExistingCLIAccountSnapshot: Equatable, Sendable {
    public let identity: String
    public let accountType: String
    public let capabilities: [String]
}

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

    public func discoverGoogleAccounts(
        executable: String = "zele"
    ) async throws -> [ExistingCLIAccountSnapshot] {
        let output = try await capture(executable: executable, arguments: ["whoami"], connector: "zele")
        return try FlatYAMLListParser.parse(output).compactMap { item in
            guard let identity = item["email"], !identity.isEmpty else { return nil }
            return ExistingCLIAccountSnapshot(
                identity: identity,
                accountType: item["type"] ?? "google",
                capabilities: (item["capabilities"] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
    }

    public func listGoogleCalendars(
        accounts: [String] = [],
        executable: String = "zele"
    ) async throws -> [PersonalCalendarSourceSnapshot] {
        let output = try await capture(
            executable: executable,
            arguments: accountArguments(accounts) + ["cal", "list"],
            connector: "zele"
        )
        return try FlatYAMLListParser.parse(output).compactMap { item in
            guard let identifier = item["id"], let name = item["name"] else { return nil }
            return PersonalCalendarSourceSnapshot(
                accountIdentity: item["account"] ?? accounts.first ?? "Google",
                externalIdentifier: identifier,
                name: name,
                role: item["role"] ?? "reader",
                isPrimary: item["primary"] == "true"
            )
        }
    }

    public func listGoogleInbox(
        accounts: [String] = [],
        limit: Int = 40,
        executable: String = "zele"
    ) async throws -> [PersonalMailThreadSnapshot] {
        let boundedLimit = min(max(limit, 1), 100)
        let output = try await capture(
            executable: executable,
            arguments: accountArguments(accounts) + ["mail", "list", "--folder", "inbox", "--limit", "\(boundedLimit)"],
            connector: "zele"
        )
        return try FlatYAMLListParser.parse(output).compactMap { item in
            guard let identifier = item["id"], let subject = item["subject"] else { return nil }
            return PersonalMailThreadSnapshot(
                accountIdentity: item["account"] ?? accounts.first ?? "Gmail",
                externalIdentifier: identifier,
                flags: item["flags"] ?? "",
                sender: item["from"] ?? "Unknown sender",
                subject: subject,
                snippet: item["snippet"] ?? "",
                dateDescription: item["date"] ?? "",
                messageCount: Int(item["messages"] ?? "") ?? 1
            )
        }
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

    private func accountArguments(_ accounts: [String]) -> [String] {
        accounts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap { ["--account", $0] }
    }
}

enum FlatYAMLListParser {
    static func parse(_ document: String) throws -> [[String: String]] {
        var items: [[String: String]] = []
        var current: [String: String]?
        var insideItems = false

        for rawLine in document.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line == "items: []" { return [] }
            if line == "items:" {
                insideItems = true
                continue
            }
            guard insideItems else { continue }
            if !line.hasPrefix(" ") { break }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                if let current { items.append(current) }
                current = [:]
                try assign(String(trimmed.dropFirst(2)), to: &current)
            } else if current != nil {
                try assign(trimmed, to: &current)
            }
        }
        if let current { items.append(current) }
        return items
    }

    private static func assign(_ field: String, to item: inout [String: String]?) throws {
        guard let separator = field.firstIndex(of: ":") else {
            throw PersonalIntegrationError.malformedOutput("zele")
        }
        let key = String(field[..<separator])
        let rawValue = String(field[field.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        item?[key] = scalar(rawValue)
    }

    private static func scalar(_ value: String) -> String {
        guard value.count >= 2, value.first == "'", value.last == "'" else { return value }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
}
