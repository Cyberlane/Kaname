import Foundation
import Testing
@testable import KanameConnectivity
@testable import KanameDomain
#if canImport(EventKit)
import EventKit
#endif

struct ProviderConnectivityTests {
    @Test
    func providerChildPathKeepsTheResolvedRuntimeDirectoryInAppLaunches() {
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        let path = LocalProcess.childSearchPath(
            executableURL: executable,
            environment: ["PATH": "/usr/bin:/bin"]
        ).split(separator: ":").map(String.init)

        #expect(path.first == "/opt/homebrew/bin")
        #expect(path.contains("/usr/bin"))
        #expect(path.filter { $0 == "/opt/homebrew/bin" }.count == 1)
    }

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
    func providerCapabilityCacheRoundTripsWithPrivatePermissions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-provider-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProviderCapabilityCacheStore(directory: root)
        let checkedAt = Date(timeIntervalSince1970: 1_786_317_600)
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "codexLocal")!,
            driver: .codex,
            displayName: "Codex"
        )
        let capability = ProviderCapabilitySnapshot(
            instance: instance,
            state: .ready,
            installed: true,
            version: "1.2.3",
            authentication: .authenticated,
            models: [],
            checkedAt: checkedAt,
            detail: "Available"
        )
        let snapshot = ProviderCapabilityCacheSnapshot(
            capabilities: [capability],
            checkedAt: checkedAt
        )

        try await store.save(snapshot)

        #expect(try await store.load() == snapshot)
        let cacheFile = root.appending(path: "provider-capabilities.json")
        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        )
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: cacheFile.path)[.posixPermissions] as? NSNumber
        )
        #expect(directoryMode.intValue & 0o777 == 0o700)
        #expect(fileMode.intValue & 0o777 == 0o600)
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
    func googleDesktopClientConfigurationAndPKCERequestAreNativeAndBounded() throws {
        let configuration = try GoogleOAuthClientConfiguration.decode(downloadedJSON: Data(
            """
            {"installed":{"client_id":"desktop.apps.googleusercontent.com","client_secret":"local-only","auth_uri":"https://accounts.google.com/o/oauth2/v2/auth","token_uri":"https://oauth2.googleapis.com/token"}}
            """.utf8
        ))
        let request = try GoogleOAuthRequestBuilder.make(
            configuration: configuration,
            redirectURI: URL(string: "http://127.0.0.1:43123/oauth/callback")!,
            verifier: String(repeating: "v", count: 48),
            state: String(repeating: "s", count: 32)
        )
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(configuration.clientID == "desktop.apps.googleusercontent.com")
        #expect(query["redirect_uri"] == "http://127.0.0.1:43123/oauth/callback")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["access_type"] == "offline")
        #expect(query["scope"]?.contains("gmail.readonly") == true)
        #expect(query["scope"]?.contains("calendar.readonly") == true)
    }

#if os(macOS)
    @Test
    func desktopInstanceLockRejectsASecondDevelopmentOrInstalledProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaname-instance-lock-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let lockFile = directory.appending(path: "desktop-instance.lock", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let primary = try KanameDesktopInstanceLock(lockFileURL: lockFile)
            #expect(throws: KanameDesktopInstanceLockError.alreadyRunning) {
                try KanameDesktopInstanceLock(lockFileURL: lockFile)
            }
            withExtendedLifetime(primary) {}
        }
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let lockFileMode = try FileManager.default.attributesOfItem(atPath: lockFile.path)[.posixPermissions] as? Int
        #expect(directoryMode == 0o700)
        #expect(lockFileMode == 0o600)

        let replacement = try KanameDesktopInstanceLock(lockFileURL: lockFile)
        _ = replacement
    }

    @Test
    func stableAndCandidateDesktopEnvironmentsNeverShareMutableState() {
        let base = URL(fileURLWithPath: "/tmp/kaname-environment-test", isDirectory: true)
        let stable = KanameDesktopEnvironment(channel: .stable, applicationSupportDirectory: base)
        let candidate = KanameDesktopEnvironment(channel: .candidate, applicationSupportDirectory: base)

        #expect(stable.bundleIdentifier == "com.cyberlane.kaname.desktop")
        #expect(candidate.bundleIdentifier == "com.cyberlane.kaname.desktop.candidate")
        #expect(stable.applicationSupportRoot != candidate.applicationSupportRoot)
        #expect(stable.instanceLockURL != candidate.instanceLockURL)
        #expect(stable.workspaceFileURL != candidate.workspaceFileURL)
        #expect(stable.providerStateDirectory != candidate.providerStateDirectory)
        #expect(stable.connectivityDirectory != candidate.connectivityDirectory)
        #expect(stable.googleDirectory != candidate.googleDirectory)
        #expect(stable.googleKeychainService != candidate.googleKeychainService)
        #expect(stable.localCoreMachService != candidate.localCoreMachService)
        #expect(stable.activationNotificationName != candidate.activationNotificationName)
    }

    @Test
    func durableConversationServiceQueuesControlsAndEvidencePrivately() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-conversation-service-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KanameConversationServiceStore(rootDirectory: root)
        let request = KanameConversationServiceRequest(
            runID: "run-1",
            threadID: "thread-1",
            projectID: "project-1",
            provider: "Codex",
            model: "gpt-5.6-terra",
            reasoningEffort: "xhigh",
            prompt: "Read-only check",
            workspacePath: "/tmp/workspace",
            providerStatePath: "/tmp/provider",
            resumableNativeThreadID: nil,
            localCoreMachService: "service",
            localCoreRequirement: "requirement",
            createdAtUnixMillis: 1_000
        )
        try store.enqueue(request)
        let queued = try store.pendingRequests(threadID: "thread-1")
        #expect(queued.map(\.1) == [request])
        #expect((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let event = KanameConversationServiceEvent.record(
            id: "run-1-service-1",
            runID: "run-1",
            threadID: "thread-1",
            ordinal: 1,
            kind: .provider,
            providerKind: .runStarted,
            nativeType: "turn/start",
            nativeThreadID: "native-thread",
            nativeTurnID: "native-turn",
            approvalID: nil,
            text: nil,
            rawPayloadBase64: nil,
            payloadWasTruncated: false,
            createdAtUnixMillis: 1_001
        )
        try store.append(event)
        #expect(try store.events(threadID: "thread-1") == [event])
        try store.acknowledge(event)
        #expect(try store.events(threadID: "thread-1").isEmpty)
        try store.requestInterrupt(threadID: "thread-1", runID: "run-1")
        #expect(store.consumeInterrupt(threadID: "thread-1", runID: "run-1"))
        #expect(!store.consumeInterrupt(threadID: "thread-1", runID: "run-1"))
        try store.requestAnswer(
            threadID: "thread-1",
            runID: "run-1",
            requestID: "question-request",
            answers: ["question-1": ["Proceed"]]
        )
        let answer = try #require(store.consumeAnswer(threadID: "thread-1", runID: "run-1"))
        #expect(answer.0 == "question-request")
        #expect(answer.1 == ["question-1": ["Proceed"]])
        try store.finishRequest(at: queued[0].0, threadID: "thread-1")
        #expect(try store.pendingRequests(threadID: "thread-1").isEmpty)
    }

    @Test
    func googleLoopbackReceiverBindsBeforeCompletingCallback() async throws {
        let receiver = try await GoogleLoopbackReceiver.start()
        let expectedState = "state-\(UUID().uuidString)"
        let expectedCode = "code-\(UUID().uuidString)"
        var callback = URLComponents(url: receiver.redirectURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [
            URLQueryItem(name: "code", value: expectedCode),
            URLQueryItem(name: "state", value: expectedState),
        ]

        async let callbackResult = URLSession.shared.data(from: callback.url!)
        let receivedCode = try await receiver.waitForCode(expectedState: expectedState)
        receiver.finish(connected: true)
        let (body, response) = try await callbackResult

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(receivedCode == expectedCode)
        #expect(String(decoding: body, as: UTF8.self).contains("securely saved"))
    }

    @Test
    func googleTokenKeychainStoreWorksWithoutAuthenticationUI() throws {
        let store = GoogleTokenKeychainStore(
            service: "com.cyberlane.kaname.google-oauth-test.\(UUID().uuidString)"
        )
        let accountID = "test-account"
        let token = Data("local-token-fixture".utf8)
        defer { try? store.remove(accountID: accountID) }

        try store.store(token, accountID: accountID)

        #expect(try store.load(
            accountID: accountID,
            identity: "fixture@example.test",
            allowInteraction: false
        ) == token)
        try store.remove(accountID: accountID)
        #expect(throws: NativeGoogleIntegrationError.self) {
            try store.load(
                accountID: accountID,
                identity: "fixture@example.test",
                allowInteraction: false
            )
        }
    }
#endif

    @Test
    func nativeGoogleResponsesPreserveAccountScopedCalendarAndMailFields() throws {
        let account = NativeGoogleAccountSnapshot(
            id: "google-subject-1",
            identity: "one@example.test",
            displayName: "One",
            capabilities: ["Gmail", "Google Calendar"]
        )
        let calendarPage = try GoogleAPIResponseParser.calendarPage(
            data: Data(
                """
                {"items":[{"id":"primary","summary":"Personal","accessRole":"owner","primary":true},{"id":"shared","summary":"Team","accessRole":"reader"}],"nextPageToken":"page-2"}
                """.utf8
            ),
            account: account
        )
        let calendars = calendarPage.calendars
        let thread = try GoogleAPIResponseParser.thread(
            data: Data(
                """
                {"id":"thread-1","snippet":"Review it","messages":[{"labelIds":["INBOX","UNREAD"],"payload":{"headers":[{"name":"From","value":"Team <team@example.test>"},{"name":"Subject","value":"It's ready: review"},{"name":"Date","value":"Sun, 10 Aug 2026 09:00:00 +0900"}]}},{"labelIds":["INBOX"],"payload":{"headers":[{"name":"From","value":"Team <team@example.test>"},{"name":"Subject","value":"Re: It's ready: review"},{"name":"Date","value":"Sun, 10 Aug 2026 10:00:00 +0900"}]}}]}
                """.utf8
            ),
            account: account
        )

        #expect(calendars.count == 2)
        #expect(calendars[0].accountIdentity == "one@example.test")
        #expect(calendars[0].isPrimary)
        #expect(calendars[1].role == "reader")
        #expect(calendarPage.nextPageToken == "page-2")
        #expect(thread.accountIdentity == "one@example.test")
        #expect(thread.subject == "Re: It's ready: review")
        #expect(thread.messageCount == 2)
        #expect(thread.flags == "INBOX, UNREAD")
    }

#if canImport(EventKit)
    @Test
    func appleCalendarAuthorizationMapsWithoutRequestingPermission() {
        #expect(AppleCalendarIntegrationService.accessState(for: .notDetermined) == .notRequested)
        #expect(AppleCalendarIntegrationService.accessState(for: .denied) == .denied)
        #expect(AppleCalendarIntegrationService.accessState(for: .restricted) == .restricted)
        if #available(macOS 14.0, *) {
            #expect(AppleCalendarIntegrationService.accessState(for: .fullAccess) == .ready)
        }
    }
#endif

    @Test
    func nativeProviderDiscussionParsesClaudeAndOpenCodeResponses() throws {
        let claude = try NativeProviderDiscussionService.parse(
            driver: .claude,
            output: #"{"result":"Plan safely.","session_id":"claude-session"}"#
        )
        #expect(claude.text == "Plan safely.")
        #expect(claude.sessionIdentifier == "claude-session")

        let openCode = try NativeProviderDiscussionService.parse(
            driver: .openCode,
            output: """
            {"type":"step_start","sessionID":"open-session"}
            {"type":"text","part":{"text":"First step."}}
            {"type":"text","part":{"text":"Second step."}}
            """
        )
        #expect(openCode.text == "First step.\nSecond step.")
        #expect(openCode.sessionIdentifier == "open-session")
    }

    @Test
    func nativeProviderDiscussionUsesPlanModeWithoutAutoApproval() async throws {
        let executable = try makeFixtureExecutable("""
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = "--auto" ]; then
            exit 99
          fi
        done
        printf '%s\\n' '{"type":"text","sessionID":"fixture","part":{"text":"Plan only."}}'
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let result = try await NativeProviderDiscussionService(timeout: .seconds(2)).run(
            driver: .openCode,
            prompt: "Review only",
            workspace: executable.deletingLastPathComponent(),
            executable: executable.path
        )
        #expect(result.text == "Plan only.")
        #expect(result.sessionIdentifier == "fixture")
    }

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
