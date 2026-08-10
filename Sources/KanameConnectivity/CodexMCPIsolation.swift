import Foundation

/// Requires an isolated Codex home and a profile with no configured MCP
/// servers. Configuration inspection is necessary but not sufficient: Kaname
/// also observes the exact initialized app-server connection before loading a
/// thread, then observes the loaded thread before sending a turn.
enum CodexMCPIsolation {
    /// The current installed app-server normally reports its initialization and
    /// thread startup state immediately. Keep the window bounded but long
    /// enough to drain asynchronous startup notifications before advancing to
    /// the next authority boundary.
    static let attestationObservationWindow: Duration = .seconds(2)

    private struct Server: Decodable, Equatable {
        let name: String
        let enabled: Bool
    }

    /// A provider child must not inherit the surrounding agent harness's MCP
    /// credential or parent-thread routing. Strip current and future T3 host
    /// variables as a family rather than relying on one secret's exact name.
    static func inheritedEnvironmentRemovals(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<String> {
        Set(environment.keys.filter { $0.hasPrefix("T3_") })
            .union(["CODEX_THREAD_ID"])
    }

    static func launchArguments(
        executable: String,
        workingDirectory: URL,
        timeout: Duration,
        codexHome: URL?,
        baseArguments: [String]
    ) async throws -> [String] {
        let enforcedArguments = try enforcedLaunchArguments(baseArguments: baseArguments)

        let environment = codexEnvironment(home: codexHome)
        let discovered = try await configuredServers(
            executable: executable,
            workingDirectory: workingDirectory,
            timeout: timeout,
            environment: environment,
            arguments: enforcedArguments
        )
        guard discovered.isEmpty else {
            throw CodexLiveSessionError.mcpConfigurationPresent
        }
        return enforcedArguments
    }

    static func codexEnvironment(home: URL?) -> [String: String] {
        home.map { ["CODEX_HOME": $0.path] } ?? [:]
    }

    static func enforcedLaunchArguments(baseArguments: [String]) throws -> [String] {
        guard !baseArguments.contains(where: { argument in
            argument.contains("mcp_servers") || argument == "apps" || argument.contains("features.apps")
        }) else {
            throw CodexLiveSessionError.mcpConfigurationPresent
        }

        // Codex Apps are exposed through an implicit MCP server at thread
        // startup and are not returned by `codex mcp list --json`. The current
        // installed runtime proved that disabling this stable feature removes
        // the implicit startup while disabling plugins or code_mode_host does
        // not. Keep the override explicit and last so Kaname owns the result.
        return baseArguments + ["--disable", "apps"]
    }

    static func indicatesUnsafeStartup(method: String, parameters: Data) -> Bool {
        guard method == "mcpServer/startupStatus/updated",
              let value = try? JSONSerialization.jsonObject(with: parameters)
        else {
            return false
        }
        return startupStates(in: value).contains { state in
            ["starting", "ready", "failed", "error"].contains(state.lowercased())
        }
    }

    private static func configuredServers(
        executable: String,
        workingDirectory: URL,
        timeout: Duration,
        environment: [String: String],
        arguments: [String]
    ) async throws -> [Server] {
        let result = try await LocalProcess.capture(
            executable: executable,
            arguments: ["mcp", "list", "--json"] + arguments,
            workingDirectory: workingDirectory,
            timeout: timeout,
            environmentOverrides: environment,
            environmentRemovals: inheritedEnvironmentRemovals()
        )
        guard result.exitStatus == 0 else {
            let detail = result.standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .first
                .map { String($0.prefix(240)) }
                ?? "exit status \(result.exitStatus)"
            throw CodexLiveSessionError.malformedResponse("Codex could not inspect the isolated MCP inventory: \(detail)")
        }
        guard let servers = try? JSONDecoder().decode([Server].self, from: Data(result.standardOutput.utf8)) else {
            throw CodexLiveSessionError.malformedResponse("Codex returned an unreadable isolated MCP inventory")
        }
        return servers
    }

    private static func startupStates(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, nestedValue in
                if ["status", "state"].contains(key.lowercased()), let state = nestedValue as? String {
                    return [state]
                }
                return startupStates(in: nestedValue)
            }
        }
        if let values = value as? [Any] {
            return values.flatMap(startupStates)
        }
        return []
    }
}
