import Foundation
import KanameDomain

enum ClaudeCapabilityProbe {
    static func probe(_ configuration: ProviderProbeConfiguration) async throws -> ProviderCapabilitySnapshot {
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
                detail: Self.nonEmpty(result.standardError) ?? Self.nonEmpty(result.standardOutput)
            )
        }

        // T3 uses the Claude Agent SDK's initialization result to enrich this
        // probe when that SDK is bundled. Kaname keeps the same fallback
        // behaviour in its Swift-only Phase 0 host: verify the native CLI and
        // report auth as unknown rather than sending a prompt or inferring that
        // an installed binary is authenticated.
        return ProviderCapabilitySnapshot(
            instance: configuration.instance,
            state: .degraded,
            installed: true,
            version: version(in: result.standardOutput + "\n" + result.standardError),
            authentication: .unknown,
            detail: "Claude CLI is available. Authentication and command inventory require the optional Claude Agent SDK handshake; no prompt was sent."
        )
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
