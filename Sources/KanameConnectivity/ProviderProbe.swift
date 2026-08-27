import Foundation
import KanameDomain

public struct OpenCodeEndpointConfiguration: Sendable {
    public let serverURL: URL?
    /// Supplied by an owning credentials provider at call time. It is never
    /// included in a snapshot, log line, or serializable configuration.
    public let serverPassword: String?

    public init(serverURL: URL? = nil, serverPassword: String? = nil) {
        self.serverURL = serverURL
        self.serverPassword = serverPassword
    }
}

public struct ProviderProbeConfiguration: Sendable {
    public let instance: ProviderInstance
    public let executable: String
    public let workingDirectory: URL
    public let timeout: Duration
    public let codexHome: URL?
    public let codexLaunchArguments: [String]
    public let openCode: OpenCodeEndpointConfiguration

    public init(
        instance: ProviderInstance,
        executable: String,
        workingDirectory: URL,
        timeout: Duration = .seconds(10),
        codexHome: URL? = nil,
        codexLaunchArguments: [String] = [],
        openCode: OpenCodeEndpointConfiguration = .init()
    ) {
        self.instance = instance
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.codexHome = codexHome
        self.codexLaunchArguments = codexLaunchArguments
        self.openCode = openCode
    }
}

/// T3-style capability probing entry point. Each driver uses its own native
/// control channel; an unavailable driver produces a usable snapshot rather
/// than preventing the rest of the control plane from starting.
public actor ProviderCapabilityProber {
    public init() {}

    public func probe(_ configuration: ProviderProbeConfiguration) async -> ProviderCapabilitySnapshot {
        do {
            if configuration.instance.driver == .codex {
                return try await CodexCapabilityProbe.probe(configuration)
            }
            if configuration.instance.driver == .claudeAgent {
                return try await ClaudeCapabilityProbe.probe(configuration)
            }
            if configuration.instance.driver == .openCode {
                return try await OpenCodeCapabilityProbe.probe(configuration)
            }
            if configuration.instance.driver == .cursorAgent {
                return try await CursorCapabilityProbe.probe(configuration)
            }
            if configuration.instance.driver == .grokBuild {
                return try await GrokCapabilityProbe.probe(configuration)
            }
            return ProviderCapabilitySnapshot(
                instance: configuration.instance,
                state: .unsupported,
                installed: false,
                authentication: .unknown,
                detail: "This Kaname build has no connector for driver '\(configuration.instance.driver.rawValue)'."
            )
        } catch let error as ProviderConnectivityError {
            return unavailableSnapshot(for: configuration.instance, error: error)
        } catch {
            return unavailableSnapshot(for: configuration.instance, error: error)
        }
    }

    private func unavailableSnapshot(for instance: ProviderInstance, error: Error) -> ProviderCapabilitySnapshot {
        let installed: Bool
        if case ProviderConnectivityError.executableNotFound = error {
            installed = false
        } else {
            installed = true
        }

        return ProviderCapabilitySnapshot(
            instance: instance,
            state: .unavailable,
            installed: installed,
            authentication: .unknown,
            detail: error.localizedDescription
        )
    }
}
