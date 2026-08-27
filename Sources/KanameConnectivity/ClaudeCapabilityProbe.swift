import Foundation
import KanameDomain

enum ClaudeCapabilityProbe {
    static func probe(_ configuration: ProviderProbeConfiguration) async throws -> ProviderCapabilitySnapshot {
        // T3 uses the Claude Agent SDK's initialization result to enrich this
        // probe when that SDK is bundled. Kaname keeps the same fallback
        // behaviour in its Swift-only Phase 0 host: verify the native CLI and
        // report auth as unknown rather than sending a prompt or inferring that
        // an installed binary is authenticated. Cursor and Grok share the
        // version probe helper; Claude keeps this named entry point so Settings
        // and ProviderProbe can continue routing through an explicit Claude
        // adapter without inventing an SDK handshake in this spike.
        let detail = """
        Claude CLI is available. Authentication and command inventory require \
        the optional Claude Agent SDK handshake; no prompt was sent.
        """
        let snapshot = try await ProviderVersionCapabilityProbe.probe(configuration, detail: detail)
        guard snapshot.installed else { return snapshot }
        return ProviderCapabilitySnapshot(
            instance: snapshot.instance,
            state: snapshot.state,
            installed: snapshot.installed,
            version: snapshot.version,
            authentication: snapshot.authentication,
            detail: snapshot.detail
        )
    }
}
