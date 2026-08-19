import Foundation
import Testing
@testable import KanameConnectivity
@testable import KanameDomain
#if os(macOS)
import Security
#endif
#if canImport(EventKit)
import EventKit
#endif

struct ProviderConnectivityTests {
    @Test
    func projectIntakeParsesGitHubHTTPSAndSSHReferencesWithoutEmbeddedCredentials() throws {
        let slug = try DesktopProjectIntakeService.parseRemoteReference("Cyberlane/Kaname")
        let suffixedSlug = try DesktopProjectIntakeService.parseRemoteReference("Cyberlane/Kaname.git")
        let https = try DesktopProjectIntakeService.parseRemoteReference("https://code.example.com/team/tool.git")
        let ssh = try DesktopProjectIntakeService.parseRemoteReference("git@github.com:Cyberlane/Kaname.git")

        #expect(slug.cloneURL == "https://github.com/Cyberlane/Kaname.git")
        #expect(slug.suggestedName == "Kaname")
        #expect(suffixedSlug.cloneURL == "https://github.com/Cyberlane/Kaname.git")
        #expect(suffixedSlug.suggestedName == "Kaname")
        #expect(https.suggestedName == "tool")
        #expect(ssh.suggestedName == "Kaname")
        #expect(throws: DesktopProjectIntakeError.self) {
            try DesktopProjectIntakeService.parseRemoteReference("https://user:secret@example.com/team/tool.git")
        }
        #expect(throws: DesktopProjectIntakeError.self) {
            try DesktopProjectIntakeService.parseRemoteReference("file:///tmp/private")
        }
        #expect(throws: DesktopProjectIntakeError.self) {
            try DesktopProjectIntakeService.parseRemoteReference("https://example.com/team/../tool.git")
        }
    }

    @Test
    func projectIntakeCanonicalizesSelectionAndFindsRepositoryInstructions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-project-intake-\(UUID().uuidString)", directoryHint: .isDirectory)
        let repository = root.appending(path: "Repository", directoryHint: .isDirectory)
        let selected = repository.appending(path: "Sources", directoryHint: .isDirectory)
        let alias = root.appending(path: "Alias", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: selected.appending(path: ".cursor/rules", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("# Instructions".utf8).write(to: repository.appending(path: "AGENTS.md"))
        try runGit(["init"], at: repository)
        try runGit(["config", "user.email", "kaname@example.invalid"], at: repository)
        try runGit(["config", "user.name", "Kaname Tests"], at: repository)
        try runGit(["add", "AGENTS.md"], at: repository)
        try runGit(["commit", "-m", "fixture"], at: repository)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: selected)

        let snapshot = try await DesktopProjectIntakeService().inspectLocalDirectory(path: alias.path)

        #expect(snapshot.canonicalSelectedPath == selected.path)
        #expect(snapshot.repository?.root.hasSuffix("/Repository") == true)
        #expect(snapshot.isRepositorySubfolder)
        #expect(snapshot.instructionReferences == ["AGENTS.md", "Sources/.cursor/rules"])
        #expect(snapshot.selectedInstructionReferences == [".cursor/rules"])
    }

    @Test
    func projectIntakeClonesThroughPrivateStagingAndCleansUpFailures() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-project-clone-\(UUID().uuidString)", directoryHint: .isDirectory)
        let origin = root.appending(path: "origin.git", directoryHint: .isDirectory)
        let destinationParent = root.appending(path: "Checkouts", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        try runGit(["init", "--bare", origin.path], at: root)
        let service = DesktopProjectIntakeService()
        let valid = DesktopRemoteProjectReference(
            cloneURL: origin.path,
            suggestedName: "cloned-project",
            displayName: "local fixture"
        )

        let snapshot = try await service.cloneRemote(reference: valid, parentDirectory: destinationParent.path)

        #expect(snapshot.canonicalSelectedPath.hasSuffix("/Checkouts/cloned-project"))
        #expect(snapshot.repository != nil)
        #expect(snapshot.repository?.head == "No commits")
        #expect(snapshot.repository?.branch == "main" || snapshot.repository?.branch == "master")
        let invalid = DesktopRemoteProjectReference(
            cloneURL: root.appending(path: "missing.git").path,
            suggestedName: "failed-project",
            displayName: "missing fixture"
        )
        await #expect(throws: Error.self) {
            _ = try await service.cloneRemote(reference: invalid, parentDirectory: destinationParent.path)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destinationParent.path)
        #expect(!leftovers.contains(where: { $0.hasPrefix(".kaname-clone-") }))
        #expect(!FileManager.default.fileExists(atPath: destinationParent.appending(path: "failed-project").path))
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

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
    func unknownAndMissingDriversProduceDistinctFailureSnapshots() async {
        let unsupported = await capabilitySnapshot(
            id: "communityFork",
            driver: ProviderDriverKind(rawValue: "communityFork")!,
            displayName: "Community Fork",
            executable: "not-used"
        )
        let unavailable = await capabilitySnapshot(
            id: "codexLocal",
            driver: .codex,
            displayName: "Codex local",
            executable: "kaname-definitely-missing-codex"
        )

        #expect(unsupported.state == .unsupported)
        #expect(unavailable.state == .unavailable)
        #expect([unsupported, unavailable].allSatisfy { !$0.installed && $0.authentication == .unknown })
    }

    private func capabilitySnapshot(
        id: String,
        driver: ProviderDriverKind,
        displayName: String,
        executable: String
    ) async -> ProviderCapabilitySnapshot {
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: id)!,
            driver: driver,
            displayName: displayName
        )
        return await ProviderCapabilityProber().probe(ProviderProbeConfiguration(
            instance: instance,
            executable: executable,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ))
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
        #expect(DesktopLocalReadService.branch(from: "## No commits yet on main...origin/main [gone]") == "main")
    }

    @Test
    func desktopGitInspectionIsBoundedAndReadOnly() async throws {
        let expectedRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL.path
        let inspection = try await DesktopLocalReadService().inspectGitWorkspace(
            path: FileManager.default.currentDirectoryPath
        )

        #expect(inspection.root == expectedRoot)
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
        #expect(query["scope"]?.contains("gmail.modify") == true)
        #expect(query["scope"]?.contains("gmail.compose") == true)
        #expect(query["scope"]?.contains("calendar.calendarlist.readonly") == true)
        #expect(query["scope"]?.contains("calendar.events") == true)
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
    func desktopEnvironmentsNeverShareMutableState() {
        let base = URL(fileURLWithPath: "/tmp/kaname-environment-test", isDirectory: true)
        let stable = KanameDesktopEnvironment(channel: .stable, applicationSupportDirectory: base)
        let candidate = KanameDesktopEnvironment(channel: .candidate, applicationSupportDirectory: base)
        let development = KanameDesktopEnvironment(channel: .development, applicationSupportDirectory: base)

        #expect(stable.bundleIdentifier == "com.cyberlane.kaname.desktop")
        #expect(candidate.bundleIdentifier == "com.cyberlane.kaname.desktop.candidate")
        #expect(development.bundleIdentifier == "com.cyberlane.kaname.desktop.dev")
        #expect(stable.applicationSupportRoot != candidate.applicationSupportRoot)
        #expect(stable.applicationSupportRoot != development.applicationSupportRoot)
        #expect(candidate.applicationSupportRoot != development.applicationSupportRoot)
        #expect(stable.instanceLockURL != candidate.instanceLockURL)
        #expect(stable.instanceLockURL != development.instanceLockURL)
        #expect(candidate.instanceLockURL != development.instanceLockURL)
        #expect(stable.workspaceFileURL != candidate.workspaceFileURL)
        #expect(stable.workspaceFileURL != development.workspaceFileURL)
        #expect(candidate.workspaceFileURL != development.workspaceFileURL)
        #expect(stable.providerStateDirectory != candidate.providerStateDirectory)
        #expect(stable.providerStateDirectory != development.providerStateDirectory)
        #expect(candidate.providerStateDirectory != development.providerStateDirectory)
        #expect(stable.connectivityDirectory != candidate.connectivityDirectory)
        #expect(stable.connectivityDirectory != development.connectivityDirectory)
        #expect(candidate.connectivityDirectory != development.connectivityDirectory)
        #expect(stable.googleDirectory != candidate.googleDirectory)
        #expect(stable.googleDirectory != development.googleDirectory)
        #expect(candidate.googleDirectory != development.googleDirectory)
        #expect(stable.googleKeychainService != candidate.googleKeychainService)
        #expect(stable.googleKeychainService != development.googleKeychainService)
        #expect(candidate.googleKeychainService != development.googleKeychainService)
        #expect(stable.localCoreMachService != candidate.localCoreMachService)
        #expect(stable.localCoreMachService != development.localCoreMachService)
        #expect(candidate.localCoreMachService != development.localCoreMachService)
        #expect(stable.activationNotificationName != candidate.activationNotificationName)
        #expect(stable.activationNotificationName != development.activationNotificationName)
        #expect(candidate.activationNotificationName != development.activationNotificationName)
    }

    @Test
    func durableConversationServiceQueuesControlsAndEvidencePrivately() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-conversation-service-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KanameConversationServiceStore(rootDirectory: root)
        let attachmentStore = KanameConversationAttachmentStore(rootDirectory: root)
        let attachment = try attachmentStore.importImage(
            data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!,
            suggestedFilename: "context.png",
            threadID: "thread-1"
        )
        let request = KanameConversationServiceRequest(
            runID: "run-1",
            threadID: "thread-1",
            projectID: "project-1",
            provider: "Codex",
            model: "gpt-5.6-terra",
            reasoningEffort: "xhigh",
            runtimeMode: .auto,
            networkAccess: true,
            prompt: "Read-only check",
            attachments: [attachment],
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
        #expect(queued.first?.1.runtimeMode == .auto)
        #expect(queued.first?.1.networkAccess == true)
        #expect(queued.first?.1.attachments == [attachment])
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
        try store.appendEvidence(Data("{\"type\":\"message\"}".utf8), threadID: "thread-1", runID: "run-1")
        let evidenceURL = try store.evidenceURL(threadID: "thread-1", runID: "run-1")
        #expect(try Data(contentsOf: evidenceURL).starts(with: Data("{\"type\":\"message\"}".utf8)))
        #expect((try FileManager.default.attributesOfItem(atPath: evidenceURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
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
        try store.writeWorkerState(KanameConversationWorkerState.record(
            threadID: "thread-1",
            runID: nil,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            updatedAtUnixMillis: 1_002
        ))
        #expect(store.isWorkerAlive(threadID: "thread-1") == false)
        try store.finishRequest(at: queued[0].0, threadID: "thread-1")
        #expect(try store.pendingRequests(threadID: "thread-1").isEmpty)
    }

    @Test
    func durableConversationRequestPreservesExactWorkspaceAuthorization() throws {
        let workspace = URL(fileURLWithPath: "/private/tmp/kaname-authorized-worktree", isDirectory: true)
        let authorization = CodexWorkspaceAuthorization(
            approvalID: "approval-exact",
            workspace: workspace,
            targetRevision: "head:digest",
            promptDigest: CodingWorkspaceInspector.digest(Data("Approved prompt".utf8)),
            model: "gpt-5.6-sol",
            reasoningEffort: "high",
            fingerprint: Data([1, 2, 3, 4]),
            expiresAt: Date(timeIntervalSince1970: 4_000),
            storePosition: 42
        )
        let request = KanameConversationServiceRequest(
            runID: "run-authorized",
            threadID: "thread-authorized",
            projectID: "project-authorized",
            provider: "Codex",
            model: "gpt-5.6-sol",
            reasoningEffort: "high",
            runtimeMode: .autoAcceptEdits,
            networkAccess: false,
            prompt: "Approved prompt",
            workspacePath: workspace.path,
            providerStatePath: "/private/tmp/provider-state",
            resumableNativeThreadID: "native-thread",
            localCoreMachService: "service",
            localCoreRequirement: "requirement",
            workspaceAuthorization: authorization,
            createdAtUnixMillis: 1_000
        )

        let decoded = try JSONDecoder().decode(
            KanameConversationServiceRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decoded == request)
        #expect(decoded.workspaceAuthorization == authorization)
        #expect(decoded.networkAccess == false)
    }

    @Test
    func codingPlanServiceRequestUsesReadOnlyNetworkDeniedNonInteractiveAuthority() {
        let request = KanameConversationServiceRequest(
            runID: "run-plan",
            threadID: "thread-plan",
            projectID: "project-plan",
            provider: "Codex",
            model: "gpt-5.6-sol",
            reasoningEffort: "high",
            runtimeMode: .fullAccess,
            networkAccess: true,
            prompt: "Plan only",
            workspacePath: "/private/tmp/workspace",
            providerStatePath: "/private/tmp/provider-state",
            resumableNativeThreadID: nil,
            localCoreMachService: "service",
            localCoreRequirement: "requirement",
            isCodingPlan: true,
            createdAtUnixMillis: 1_000
        )

        let coding = request.codexCodingRequest()
        #expect(coding.sandbox == .readOnly)
        #expect(coding.networkAccess == false)
        #expect(coding.approvalPolicy == .never)
        #expect(coding.runtimeAuthority == .workflowApprovalRequired)
    }

    @Test
    func nativeConversationAdaptersPreservePlanAuthorityResumeAndStreamingEvidence() throws {
        let workspace = URL(fileURLWithPath: "/tmp/workspace")
        let claude = NativeConversationRequest(
            driver: .claude,
            prompt: "Inspect only",
            attachmentPaths: ["/tmp/kaname-attachments/design.png"],
            workspace: workspace,
            model: "Use provider default",
            reasoningEffort: "high",
            resumableSessionID: "claude-session"
        )
        let claudeArguments = NativeProviderConversationSession.arguments(for: claude)
        #expect(claudeArguments.contains("plan"))
        #expect(claudeArguments.contains("stream-json"))
        #expect(claudeArguments.contains("--resume"))
        #expect(!claudeArguments.contains("--dangerously-skip-permissions"))
        #expect(claudeArguments.contains("--add-dir"))
        #expect(claudeArguments.last?.contains("`/tmp/kaname-attachments/design.png`") == true)
        let addDirectoryIndex = try #require(claudeArguments.firstIndex(of: "--add-dir"))
        #expect(claudeArguments[addDirectoryIndex + 2] == "--resume")

        var claudeParser = NativeProviderStreamParser(driver: .claude)
        let system = Data(#"{"type":"system","session_id":"session-1"}"#.utf8)
        let delta = Data(#"{"type":"stream_event","session_id":"session-1","event":{"delta":{"type":"text_delta","text":"Hello"}}}"#.utf8)
        #expect(claudeParser.consume(line: system).contains { $0.kind == .sessionStarted })
        let claudeEvents = claudeParser.consume(line: delta)
        #expect(claudeEvents.contains { $0.kind == .messageDelta && $0.text == "Hello" })
        #expect(claudeEvents.first?.payload == delta)
        #expect(claudeParser.sessionID == "session-1")

        let openCode = NativeConversationRequest(
            driver: .openCode,
            prompt: "Inspect only",
            attachmentPaths: ["/tmp/kaname-attachments/design.png"],
            workspace: workspace,
            model: "openai/gpt-5",
            reasoningEffort: "high",
            resumableSessionID: "oc-session"
        )
        let openCodeArguments = NativeProviderConversationSession.arguments(for: openCode)
        #expect(openCodeArguments.contains("plan"))
        #expect(openCodeArguments.contains("--session"))
        #expect(!openCodeArguments.contains("--auto"))
        #expect(openCodeArguments.contains("--file"))
        #expect(openCodeArguments.contains("/tmp/kaname-attachments/design.png"))

        let claudeFullAccess = NativeConversationRequest(
            driver: .claude,
            prompt: "Implement",
            workspace: workspace,
            model: "claude-opus-4-1",
            reasoningEffort: "max",
            runtimeMode: .fullAccess,
            resumableSessionID: nil
        )
        let claudeFullAccessArguments = NativeProviderConversationSession.arguments(for: claudeFullAccess)
        #expect(claudeFullAccessArguments.contains("bypassPermissions"))
        #expect(claudeFullAccessArguments.contains("claude-opus-4-1"))
        #expect(claudeFullAccessArguments.contains("max"))

        let openCodeAuto = NativeConversationRequest(
            driver: .openCode,
            prompt: "Implement",
            workspace: workspace,
            model: "openai/gpt-5",
            reasoningEffort: "high",
            runtimeMode: .auto,
            resumableSessionID: nil
        )
        let openCodeAutoArguments = NativeProviderConversationSession.arguments(for: openCodeAuto)
        #expect(openCodeAutoArguments.contains("build"))
        #expect(openCodeAutoArguments.contains("--auto"))
        var openCodeParser = NativeProviderStreamParser(driver: .openCode)
        let text = Data(#"{"type":"text","sessionID":"oc-session","part":{"type":"text","text":"Ready"}}"#.utf8)
        #expect(openCodeParser.consume(line: text).contains { $0.kind == .messageDelta && $0.text == "Ready" })
        #expect(openCodeParser.sessionID == "oc-session")
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

    @Test
    func nonInteractiveGoogleTokenQueriesDisableAuthenticationUIForEveryBackend() {
        let store = GoogleTokenKeychainStore(service: "com.cyberlane.kaname.google-oauth-test")
        let dataProtection = store.lookup(
            accountID: "test-account",
            backend: .dataProtection,
            allowInteraction: false
        )
        let traditional = store.lookup(
            accountID: "test-account",
            backend: .traditional,
            allowInteraction: false
        )

        #expect(dataProtection[kSecUseDataProtectionKeychain] as? Bool == true)
        #expect(dataProtection[kSecUseAuthenticationContext] != nil)
        #expect(traditional[kSecUseDataProtectionKeychain] == nil)
        #expect(traditional[kSecUseAuthenticationContext] != nil)
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

    @Test
    func managedWorktreeLifecycleRequiresExactApprovalAndRefusesDirtyCleanup() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "kaname-worktree-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let repository = sandbox.appending(path: "repository", directoryHint: .isDirectory)
        let managedRoot = sandbox.appending(path: "managed", directoryHint: .isDirectory)
        let target = managedRoot.appending(path: "feature", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try await LocalProcess.capture(executable: "git", arguments: ["init", "-b", "main"], workingDirectory: repository, timeout: .seconds(5))
        try Data("foundation\n".utf8).write(to: repository.appending(path: "README.md"))
        _ = try await LocalProcess.capture(executable: "git", arguments: ["add", "README.md"], workingDirectory: repository, timeout: .seconds(5))
        _ = try await LocalProcess.capture(
            executable: "git",
            arguments: ["-c", "user.name=Kaname Test", "-c", "user.email=test@invalid.example", "-c", "commit.gpgsign=false", "commit", "-m", "initial"],
            workingDirectory: repository,
            timeout: .seconds(5)
        )
        let service = DesktopGitControlService(managedRoot: managedRoot, timeout: .seconds(5))
        let snapshot = try await service.createWorktree(
            repository: repository,
            target: target,
            branch: "kaname/fixture",
            baseRevision: "HEAD",
            grant: LocalGitMutationGrant(approvalID: "approved-create", kind: .createWorktree, exactTarget: target.path)
        )
        #expect(snapshot.branch == "kaname/fixture")
        #expect(snapshot.changedFiles.isEmpty)

        try Data("foundation\nreviewed change\n".utf8).write(to: target.appending(path: "README.md"))
        let refreshed = try await service.inspect(worktree: target, rootRepository: repository)
        #expect(refreshed.changedFiles == ["README.md"])
        let patch = try await service.diff(worktree: target, relativePath: "README.md")
        #expect(patch.contains("+reviewed change"))
        await #expect(throws: DesktopGitControlError.invalidTarget) {
            try await service.diff(worktree: target, relativePath: "../README.md")
        }
        try Data("foundation\n".utf8).write(to: target.appending(path: "README.md"))

        try Data("dirty\n".utf8).write(to: target.appending(path: "dirty.txt"))
        let untrackedPatch = try await service.diff(worktree: target, relativePath: "dirty.txt")
        #expect(untrackedPatch.contains("+dirty"))
        await #expect(throws: DesktopGitControlError.worktreeDirty) {
            try await service.removeWorktree(
                repository: repository,
                target: target,
                grant: LocalGitMutationGrant(approvalID: "approved-remove", kind: .cleanupWorktree, exactTarget: target.path)
            )
        }
        try FileManager.default.removeItem(at: target.appending(path: "dirty.txt"))
        try await service.removeWorktree(
            repository: repository,
            target: target,
            grant: LocalGitMutationGrant(approvalID: "approved-remove", kind: .cleanupWorktree, exactTarget: target.path)
        )
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func githubPullRequestEvidenceParserPreservesChecksReviewsAndBranches() throws {
        let fixture = Data("""
        [{"number":42,"title":"Safe change","url":"https://github.com/example/repo/pull/42","headRefName":"feature","baseRefName":"main","state":"OPEN","mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"FAILURE"}],"reviews":[{"state":"APPROVED"}]}]
        """.utf8)
        let result = try GitHubControlService.decodePullRequests(fixture)
        let pullRequest = try #require(result.first)
        #expect(pullRequest.number == 42)
        #expect(pullRequest.headBranch == "feature")
        #expect(pullRequest.baseBranch == "main")
        #expect(pullRequest.checkSummary == "1/2 checks green")
        #expect(pullRequest.reviewSummary == "Approved")
        #expect(GitHubControlService.mergeTarget(repository: "example/repo", number: 42) == "example/repo#42")
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
