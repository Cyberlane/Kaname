import Foundation
import KanameDomain

/// Shared `--version` probe used by Claude, Cursor, and Grok Build adapters.
/// Driver-specific detail strings stay here so thin per-driver files do not
/// create Mori zero-fragment coverage gaps.
enum ProviderVersionCapabilityProbe {
    static func probe(_ configuration: ProviderProbeConfiguration) async throws -> ProviderCapabilitySnapshot {
        try await probe(configuration, detail: detail(for: configuration.instance.driver))
    }

    static func probe(
        _ configuration: ProviderProbeConfiguration,
        detail: String
    ) async throws -> ProviderCapabilitySnapshot {
        let result = try await LocalProcess.capture(
            executable: configuration.executable,
            arguments: ["--version"],
            workingDirectory: configuration.workingDirectory,
            timeout: configuration.timeout
        )
        guard result.exitStatus == 0 else {
            throw ProviderConnectivityError.processExited(
                command: "\(configuration.executable) --version",
                status: result.exitStatus,
                detail: nonEmpty(result.standardError) ?? nonEmpty(result.standardOutput)
            )
        }

        return ProviderCapabilitySnapshot(
            instance: configuration.instance,
            state: .degraded,
            installed: true,
            version: version(in: result.standardOutput + "\n" + result.standardError),
            authentication: .unknown,
            detail: detail
        )
    }

    private static func detail(for driver: ProviderDriverKind) -> String {
        switch driver {
        case .claudeAgent:
            // T3 uses the Claude Agent SDK's initialization result to enrich this
            // probe when that SDK is bundled. Kaname keeps the same fallback
            // behaviour in its Swift-only Phase 0 host: verify the native CLI and
            // report auth as unknown rather than sending a prompt or inferring that
            // an installed binary is authenticated.
            return "Claude CLI is available. Authentication and command inventory require the optional Claude Agent SDK handshake; no prompt was sent."
        case .cursorAgent:
            return "Cursor CLI is available. Conversation turns use print + stream-json; authentication was not probed and no prompt was sent."
        case .grokBuild:
            return "Grok Build CLI is available. Conversation turns use headless --single + streaming-messages-json; authentication was not probed and no prompt was sent."
        default:
            return "Provider CLI reported a version. Authentication was not probed; no prompt was sent."
        }
    }

    private static func version(in text: String) -> String? {
        let components = text.split(whereSeparator: { $0.isWhitespace })
        return components.first(where: { $0.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil }).map(String.init)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CursorCapabilityProbe {
    static func probe(_ configuration: ProviderProbeConfiguration) async throws -> ProviderCapabilitySnapshot {
        try await ProviderVersionCapabilityProbe.probe(configuration)
    }
}

enum GrokCapabilityProbe {
    static func probe(_ configuration: ProviderProbeConfiguration) async throws -> ProviderCapabilitySnapshot {
        try await ProviderVersionCapabilityProbe.probe(configuration)
    }
}
