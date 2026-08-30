import Foundation
import KanameDomain

/// Shared `--version` probe used by Claude, Cursor, and Grok Build adapters.
/// Driver-specific detail strings stay here so thin per-driver files do not
/// create Mori zero-fragment coverage gaps.
enum ProviderVersionCapabilityProbe {
    static func probe(_ configuration: ProviderProbeConfiguration) async throws -> ProviderCapabilitySnapshot {
        let detail = ProviderInventory.provider(id: configuration.instance.driver)?.versionProbeDetail
            ?? "Provider CLI reported a version. Authentication was not probed; no prompt was sent."
        return try await probe(configuration, detail: detail)
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

    private static func version(in text: String) -> String? {
        let components = text.split(whereSeparator: { $0.isWhitespace })
        return components.first(where: { $0.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil }).map(String.init)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
