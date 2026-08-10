import Foundation
import Testing
@testable import KanameConnectivity
@testable import KanameDomain
#if canImport(EventKit)
import EventKit
#endif

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

    @Test
    func desktopLocalReadsRejectVaultTraversalAndParseBranches() throws {
        #expect(try DesktopLocalReadService.validatedVaultPath("Projects/Coding ADE/Overview.md") == "Projects/Coding ADE/Overview.md")
        #expect(throws: DesktopLocalReadError.self) {
            try DesktopLocalReadService.validatedVaultPath("../Private.md")
        }
        #expect(DesktopLocalReadService.branch(from: "## main...origin/main [ahead 2]") == "main")
        #expect(DesktopLocalReadService.branch(from: "## feature/work") == "feature/work")
    }

    @Test
    func desktopGitInspectionIsBoundedAndReadOnly() async throws {
        let inspection = try await DesktopLocalReadService().inspectGitWorkspace(
            path: FileManager.default.currentDirectoryPath
        )

        #expect(inspection.root.hasSuffix("coding-ade"))
        #expect(!inspection.branch.isEmpty)
        #expect(inspection.head.count == 12)
        #expect(!inspection.wasTruncated)
    }

    @Test
    func flatZeleOutputPreservesAccountScopedMailAndCalendarFields() throws {
        let parsed = try FlatYAMLListParser.parse(
            """
            summary: 2 threads (inbox)
            items:
              - account: first@example.test
                id: thread-1
                subject: 'It''s ready: review'
                messages: 3
              - account: second@example.test
                id: thread-2
                subject: Another account
                messages: 1
            """
        )

        #expect(parsed.count == 2)
        #expect(parsed[0]["account"] == "first@example.test")
        #expect(parsed[0]["subject"] == "It's ready: review")
        #expect(parsed[1]["id"] == "thread-2")
    }

    @Test
    func personalIntegrationDiscoversEveryExistingCLIAccountWithoutTokens() async throws {
        let executable = try makeFixtureExecutable(
            """
            #!/bin/sh
            printf '%s\n' \\
              'summary: 4 account(s)' \\
              'items:' \\
              '  - email: one@example.test' \\
              '    type: google' \\
              "    capabilities: 'gmail, calendar'" \\
              '    status: Authenticated' \\
              '  - email: two@example.test' \\
              '    type: google' \\
              "    capabilities: 'gmail, calendar'" \\
              '    status: Authenticated' \\
              '  - email: three@example.test' \\
              '    type: google' \\
              "    capabilities: 'gmail, calendar'" \\
              '    status: Authenticated' \\
              '  - email: four@example.test' \\
              '    type: google' \\
              "    capabilities: 'gmail, calendar'" \\
              '    status: Authenticated'
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let accounts = try await PersonalIntegrationService(timeout: .seconds(2))
            .discoverGoogleAccounts(executable: executable.path)

        #expect(accounts.count == 4)
        #expect(accounts.map(\.identity) == [
            "one@example.test", "two@example.test", "three@example.test", "four@example.test",
        ])
        #expect(accounts.allSatisfy { $0.capabilities == ["gmail", "calendar"] })
    }

#if canImport(EventKit)
    @Test
    func appleCalendarAuthorizationMapsWithoutRequestingPermission() {
        #expect(AppleCalendarIntegrationService.accessState(for: .notDetermined) == .notRequested)
        #expect(AppleCalendarIntegrationService.accessState(for: .denied) == .denied)
        #expect(AppleCalendarIntegrationService.accessState(for: .restricted) == .restricted)
        #expect(AppleCalendarIntegrationService.accessState(for: .fullAccess) == .ready)
    }
#endif

    private func makeFixtureExecutable(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-integration-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("connector")
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}
