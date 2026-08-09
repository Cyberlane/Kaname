import Foundation
import Testing
@testable import KanameConnectivity
@testable import KanameDomain

struct ProviderConnectivityTests {
    @Test
    func providerInstanceKeepsDriverAndRoutingIdentitySeparate() {
        let driver = ProviderDriverKind(rawValue: "communityFork")
        let instanceID = ProviderInstanceID(rawValue: "communityFork_work")

        #expect(driver?.rawValue == "communityFork")
        #expect(instanceID?.rawValue == "communityFork_work")
        #expect(ProviderDriverKind(rawValue: "not a valid driver") == nil)
        #expect(ProviderInstanceID(rawValue: "9invalid") == nil)
    }

    @Test
    func unknownDriverIsAnExplicitUnsupportedSnapshot() async {
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "communityFork")!,
            driver: ProviderDriverKind(rawValue: "communityFork")!,
            displayName: "Community Fork"
        )
        let configuration = ProviderProbeConfiguration(
            instance: instance,
            executable: "not-used",
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )

        let snapshot = await ProviderCapabilityProber().probe(configuration)

        #expect(snapshot.state == .unsupported)
        #expect(snapshot.installed == false)
        #expect(snapshot.authentication == .unknown)
    }

    @Test
    func missingNativeConnectorProducesAnUnavailableSnapshot() async {
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "codexLocal")!,
            driver: .codex,
            displayName: "Codex local"
        )
        let configuration = ProviderProbeConfiguration(
            instance: instance,
            executable: "kaname-definitely-missing-codex",
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )

        let snapshot = await ProviderCapabilityProber().probe(configuration)

        #expect(snapshot.state == .unavailable)
        #expect(snapshot.installed == false)
        #expect(snapshot.authentication == .unknown)
    }

    @Test
    func boundedNativeProcessCaptureCollectsAReadOnlyVersionStyleCommand() async throws {
        let result = try await LocalProcess.capture(
            executable: "/usr/bin/env",
            arguments: ["printf", "kaname"],
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            timeout: .seconds(2)
        )

        #expect(result.exitStatus == 0)
        #expect(result.standardOutput == "kaname")
        #expect(result.standardError.isEmpty)
    }

    @Test
    func localProcessRemovesHostHarnessVariablesBeforeLaunchingAProviderChild() async throws {
        let result = try await LocalProcess.capture(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "if test -z \"$T3_KANAME_TEST_TOKEN\" && test -z \"$CODEX_THREAD_ID\"; then printf isolated; else printf inherited; fi",
            ],
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            timeout: .seconds(2),
            environmentOverrides: [
                "T3_KANAME_TEST_TOKEN": "must-not-reach-child",
                "CODEX_THREAD_ID": "must-not-reach-child",
            ],
            environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals(from: [
                "T3_KANAME_TEST_TOKEN": "present",
            ])
        )

        #expect(result.exitStatus == 0)
        #expect(result.standardOutput == "isolated")
        #expect(result.standardError.isEmpty)
    }

    @Test
    func openCodeInventoryExcludesUnconnectedCatalogProviders() {
        let payload: [String: Any] = [
            "data": [
                "connected": ["connected"],
                "all": [
                    [
                        "id": "connected",
                        "name": "Connected",
                        "models": ["one": ["name": "One", "default": true]],
                    ],
                    [
                        "id": "catalog-only",
                        "name": "Catalog only",
                        "models": ["two": ["name": "Two"]],
                    ],
                ],
            ],
        ]

        let inventory = OpenCodeCapabilityProbe.parseProviderInventory(payload)

        #expect(inventory.connectedProviderIDs == ["connected"])
        #expect(inventory.models == [ProviderModel(id: "connected/one", displayName: "One", isDefault: true)])
    }
}
