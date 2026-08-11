import Foundation
import KanameDomain
import Testing
@testable import KanameConnectivity

struct KanameUpdateCoordinatorTests {
    @Test
    func qaApplicationSupportOverrideRequiresAnExplicitSafeAbsoluteBase() {
        #expect(KanameDesktopEnvironment.qaApplicationSupportDirectory(arguments: ["Kaname"]) == nil)
        #expect(KanameDesktopEnvironment.qaApplicationSupportDirectory(arguments: ["Kaname", "--desktop-qa-application-support-base", ".build/state"]) == nil)
        #expect(KanameDesktopEnvironment.qaApplicationSupportDirectory(arguments: ["Kaname", "--desktop-qa-application-support-base", "/"]) == nil)
        #expect(KanameDesktopEnvironment.qaApplicationSupportDirectory(
            arguments: ["Kaname", "--desktop-qa-application-support-base", "/tmp/kaname-state/../qa"]
        )?.path == "/tmp/qa")
    }

    @Test
    func releaseVersionsRequireForwardMarketingVersionOrBuild() throws {
        let current = try #require(KanameBundleVersion(version: "0.13.0", build: "22"))
        let nextBuild = try #require(KanameBundleVersion(version: "0.13", build: "23"))
        let nextVersion = try #require(KanameBundleVersion(version: "0.14.0", build: "1"))
        let older = try #require(KanameBundleVersion(version: "0.12.9", build: "99"))

        #expect(nextBuild > current)
        #expect(nextVersion > current)
        #expect(older < current)
        #expect(KanameBundleVersion(version: "0.14-beta", build: "23") == nil)
        #expect(KanameBundleVersion(version: "0.14.0", build: "not-a-build") == nil)
    }

    @Test
    func forwardPolicyRejectsSameBuildDowngradeAndInvalidMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-update-policy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try makeBundle(root: root, name: "Installed", version: "0.13.0", build: "22")

        let forward = try makeBundle(root: root, name: "Forward", version: "0.14.0", build: "1")
        try KanameUpdateCoordinator.validateForwardUpdate(currentBundleURL: installed, candidateBundleURL: forward)

        let same = try makeBundle(root: root, name: "Same", version: "0.13.0", build: "22")
        #expect(throws: KanameUpdateError.downgradeRejected) {
            try KanameUpdateCoordinator.validateForwardUpdate(currentBundleURL: installed, candidateBundleURL: same)
        }

        let downgrade = try makeBundle(root: root, name: "Downgrade", version: "0.12.0", build: "99")
        #expect(throws: KanameUpdateError.downgradeRejected) {
            try KanameUpdateCoordinator.validateForwardUpdate(currentBundleURL: installed, candidateBundleURL: downgrade)
        }

        let invalid = try makeBundle(root: root, name: "Invalid", version: "next", build: "23")
        #expect(throws: KanameUpdateError.invalidVersionMetadata) {
            try KanameUpdateCoordinator.validateForwardUpdate(currentBundleURL: installed, candidateBundleURL: invalid)
        }
    }

    @Test
    func bundleDigestIsStableAcrossCopiesAndDetectsReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-update-digest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeBundle(root: root, name: "Source", version: "0.14.0", build: "23")
        let executable = source.appending(path: "Contents/MacOS/Kaname")
        try Data("signed payload".utf8).write(to: executable)
        let copy = root.appending(path: "Copy.app", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: copy)

        let sourceDigest = try KanameUpdateCoordinator.bundleDigest(at: source)
        let copiedDigest = try KanameUpdateCoordinator.bundleDigest(at: copy)
        #expect(sourceDigest.count == 64)
        #expect(copiedDigest == sourceDigest, "source \(sourceDigest), copy \(copiedDigest)")

        try Data("replaced payload".utf8).write(to: copy.appending(path: "Contents/MacOS/Kaname"))
        #expect(try KanameUpdateCoordinator.bundleDigest(at: copy) != sourceDigest)
    }

    @Test
    func bundleDigestRejectsSymlinksThatEscapeTheBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-update-link-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root, name: "Candidate", version: "0.14.0", build: "23")
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appending(path: "Contents/escape").path,
            withDestinationPath: "../../outside"
        )

        #expect(throws: KanameUpdateError.invalidBundle) {
            try KanameUpdateCoordinator.bundleDigest(at: bundle)
        }
    }

    @Test
    func signedBundleManifestBindsChannelIdentityVersionAndReleaseNotes() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-update-manifest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root, name: "Candidate", version: "0.14.0", build: "23")
        let resources = bundle.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let expected = KanameUpdateManifest(
            schemaVersion: 1,
            channel: "stable",
            bundleIdentifier: "com.cyberlane.kaname.desktop",
            version: "0.14.0",
            build: "23",
            minimumWorkspaceSchema: 1,
            maximumWorkspaceSchema: 13,
            releaseNotes: "Search and recovery hardening."
        )
        try JSONEncoder().encode(expected).write(
            to: resources.appending(path: "KanameUpdateManifest.json")
        )

        #expect(try KanameUpdateCoordinator.updateManifest(at: bundle) == expected)
        try Data("{}".utf8).write(to: resources.appending(path: "KanameUpdateManifest.json"))
        #expect(throws: KanameUpdateError.invalidManifest) {
            try KanameUpdateCoordinator.updateManifest(at: bundle)
        }
    }

    @Test
    func updateManifestMustSupportTheCurrentWorkspaceSchema() throws {
        let base = KanameUpdateManifest(
            schemaVersion: 1,
            channel: "stable",
            bundleIdentifier: "com.cyberlane.kaname.desktop",
            version: "0.14.0",
            build: "23",
            minimumWorkspaceSchema: 1,
            maximumWorkspaceSchema: KanameDesktopStateSchema.currentVersion,
            releaseNotes: "Compatible"
        )
        try KanameUpdateCoordinator.validateWorkspaceCompatibility(base)

        var below = base
        below.maximumWorkspaceSchema = KanameDesktopStateSchema.currentVersion - 1
        #expect(throws: KanameUpdateError.invalidManifest) {
            try KanameUpdateCoordinator.validateWorkspaceCompatibility(below)
        }

        var above = base
        above.minimumWorkspaceSchema = KanameDesktopStateSchema.currentVersion + 1
        above.maximumWorkspaceSchema = above.minimumWorkspaceSchema
        #expect(throws: KanameUpdateError.invalidManifest) {
            try KanameUpdateCoordinator.validateWorkspaceCompatibility(above)
        }
    }

    @Test
    func updatePathsRejectAliasesNestingAndSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-update-paths-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try makeBundle(root: root, name: "Installed", version: "0.13.0", build: "22")
        let staged = try makeBundle(root: root, name: "Staged", version: "0.14.0", build: "23")
        let alias = root.appending(path: "Alias.app", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: staged)

        #expect(throws: KanameUpdateError.invalidBundle) {
            try KanameUpdateCoordinator.validateDistinctBundlePaths([installed, installed])
        }
        #expect(throws: KanameUpdateError.invalidBundle) {
            try KanameUpdateCoordinator.validateDistinctBundlePaths([staged, staged.appending(path: "Contents")])
        }
        #expect(throws: KanameUpdateError.invalidBundle) {
            try KanameUpdateCoordinator.validateDistinctBundlePaths([installed, alias])
        }
    }

    @Test
    func olderUpdateReceiptsRemainDecodableWithoutNewTrustFields() throws {
        let legacy = Data(#"{"status":"staged","version":"0.13.0","build":"22","detail":"Ready","updatedAtUnixMillis":1}"#.utf8)
        let receipt = try JSONDecoder().decode(KanameUpdateReceipt.self, from: legacy)
        #expect(receipt.bundleDigest == nil)
        #expect(receipt.signerDigest == nil)
        #expect(receipt.rollbackBundleDigest == nil)
        #expect(receipt.rollbackSignerDigest == nil)
        #expect(receipt.rollbackVersion == nil)
        #expect(receipt.rollbackBuild == nil)
        #expect(receipt.releaseNotes == nil)
    }

    @Test
    func updateReceiptRoundTripsPinnedRollbackIdentity() throws {
        let receipt = KanameUpdateReceipt(
            status: .switching,
            version: "0.14.0",
            build: "23",
            bundleDigest: String(repeating: "a", count: 64),
            signerDigest: String(repeating: "b", count: 64),
            rollbackBundleDigest: String(repeating: "c", count: 64),
            rollbackSignerDigest: String(repeating: "d", count: 64),
            rollbackVersion: "0.13.0",
            rollbackBuild: "22",
            releaseNotes: "Verified update",
            detail: "Switching",
            updatedAtUnixMillis: 1
        )

        #expect(try JSONDecoder().decode(KanameUpdateReceipt.self, from: JSONEncoder().encode(receipt)) == receipt)
    }

    @Test
    func rollbackRequiresPersistedComposerAndNoActiveApprovalBeforeInspectingBundles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-rollback-authority-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try makeBundle(root: root, name: "Installed", version: "0.14.0", build: "23")
        let coordinator = KanameUpdateCoordinator(
            environment: KanameDesktopEnvironment(channel: .stable, applicationSupportDirectory: root),
            currentBundleURL: installed
        )

        await #expect(throws: KanameUpdateError.unsavedComposer) {
            try await coordinator.rollbackRequest(
                installedBundleURL: installed,
                processIdentifier: 42,
                composerCheckpointed: false,
                hasActiveApproval: false
            )
        }
        await #expect(throws: KanameUpdateError.activeApproval) {
            try await coordinator.rollbackRequest(
                installedBundleURL: installed,
                processIdentifier: 42,
                composerCheckpointed: true,
                hasActiveApproval: true
            )
        }
    }

    @Test
    func localDogfoodCatalogSelectsHighestCompatibleStableBuild() async throws {
        let root = temporaryRoot("catalog-selection")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = KanameDesktopEnvironment(channel: .stable, applicationSupportDirectory: root)
        let installed = try makeBundle(root: root, name: "Installed", version: "0.15.0", build: "24")
        let artifacts = environment.dogfoodUpdateDirectory.appending(path: "Artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let build25 = try makeBundle(root: artifacts, name: "Kaname-25", version: "0.15.0", build: "25")
        let build26 = try makeBundle(root: artifacts, name: "Kaname-26", version: "0.15.0", build: "26")
        try writeCatalog([
            try release(for: build25, relativePath: "Artifacts/Kaname-25.app", notes: "First"),
            try release(for: build26, relativePath: "Artifacts/Kaname-26.app", notes: "Latest"),
        ], environment: environment)

        let catalog = KanameLocalDogfoodUpdateCatalog(environment: environment, currentBundleURL: installed)
        let update = try #require(try await catalog.latestUpdate())
        #expect(update.version == "0.15.0")
        #expect(update.build == "26")
        #expect(update.releaseNotes == "Latest")
        #expect(try await catalog.verifiedArtifactURL(for: update) == build26)
    }

    @Test
    func candidateDoesNotReadStableDogfoodCatalog() async throws {
        let root = temporaryRoot("catalog-candidate")
        defer { try? FileManager.default.removeItem(at: root) }
        let stableEnvironment = KanameDesktopEnvironment(channel: .stable, applicationSupportDirectory: root)
        let candidateEnvironment = KanameDesktopEnvironment(channel: .candidate, applicationSupportDirectory: root)
        let installed = try makeBundle(root: root, name: "Candidate", version: "0.15.0", build: "24")
        let artifacts = stableEnvironment.dogfoodUpdateDirectory.appending(path: "Artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let update = try makeBundle(root: artifacts, name: "Kaname-25", version: "0.15.0", build: "25")
        try writeCatalog([try release(for: update, relativePath: "Artifacts/Kaname-25.app")], environment: stableEnvironment)

        let catalog = KanameLocalDogfoodUpdateCatalog(environment: candidateEnvironment, currentBundleURL: installed)
        #expect(try await catalog.latestUpdate() == nil)
    }

    @Test
    func localDogfoodCatalogRejectsInvalidAndEscapingEntries() async throws {
        let root = temporaryRoot("catalog-invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = KanameDesktopEnvironment(channel: .stable, applicationSupportDirectory: root)
        let installed = try makeBundle(root: root, name: "Installed", version: "0.15.0", build: "24")
        let outside = try makeBundle(root: root, name: "Outside", version: "0.15.0", build: "25")
        var escaping = try release(for: outside, relativePath: "Artifacts/../Outside.app")
        escaping.bundleDigest = String(repeating: "a", count: 64)
        try writeCatalog([escaping], environment: environment)
        let catalog = KanameLocalDogfoodUpdateCatalog(environment: environment, currentBundleURL: installed)
        await #expect(throws: KanameUpdateDiscoveryError.unsafeArtifactPath) {
            try await catalog.latestUpdate()
        }

        var first = escaping
        first.artifactRelativePath = "Artifacts/First.app"
        var duplicate = first
        duplicate.artifactRelativePath = "Artifacts/Other.app"
        try writeCatalog([first, duplicate], environment: environment)
        await #expect(throws: KanameUpdateDiscoveryError.invalidCatalog) {
            try await catalog.latestUpdate()
        }
    }

    @Test
    func localDogfoodArtifactDigestIsRecheckedBeforeStaging() async throws {
        let root = temporaryRoot("catalog-digest")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = KanameDesktopEnvironment(channel: .stable, applicationSupportDirectory: root)
        let installed = try makeBundle(root: root, name: "Installed", version: "0.15.0", build: "24")
        let artifacts = environment.dogfoodUpdateDirectory.appending(path: "Artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let artifact = try makeBundle(root: artifacts, name: "Kaname-25", version: "0.15.0", build: "25")
        try Data("original".utf8).write(to: artifact.appending(path: "Contents/MacOS/Kaname"))
        try writeCatalog([try release(for: artifact, relativePath: "Artifacts/Kaname-25.app")], environment: environment)
        let catalog = KanameLocalDogfoodUpdateCatalog(environment: environment, currentBundleURL: installed)
        let update = try #require(try await catalog.latestUpdate())

        try Data("changed".utf8).write(to: artifact.appending(path: "Contents/MacOS/Kaname"))
        await #expect(throws: KanameUpdateDiscoveryError.artifactDigestMismatch) {
            try await catalog.verifiedArtifactURL(for: update)
        }
    }

    @Test
    func updateDiscoveryPreferencesDefaultAndRoundTripPrivately() async throws {
        let root = temporaryRoot("catalog-preferences")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = KanameDesktopEnvironment(channel: .stable, applicationSupportDirectory: root)
        let store = KanameUpdateDiscoveryPreferencesStore(environment: environment)
        #expect(await store.load() == KanameUpdateDiscoveryPreferences())
        let expected = KanameUpdateDiscoveryPreferences(
            automaticChecksEnabled: false,
            lastAttemptAtUnixMillis: 10,
            lastSuccessAtUnixMillis: 9,
            deferredIdentity: "deferred",
            deferredUntilUnixMillis: 11,
            skippedIdentity: "skipped",
            lastSourceIdentifier: "local-dogfood"
        )
        try await store.save(expected)
        #expect(await store.load() == expected)
        let attributes = try FileManager.default.attributesOfItem(atPath: environment.dogfoodUpdatePreferencesURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func updateNoticeProjectsOnlyActionableStableStates() {
        let update = KanameAvailableUpdate(
            sourceIdentifier: "local-dogfood",
            sourceLabel: "Local dogfood",
            channel: .stable,
            version: "0.17.1",
            build: "30",
            bundleIdentifier: "com.cyberlane.kaname.desktop",
            publishedAtUnixMillis: 1,
            releaseNotes: "Visible local proof",
            minimumWorkspaceSchema: 1,
            maximumWorkspaceSchema: KanameDesktopStateSchema.currentVersion,
            artifactURL: URL(fileURLWithPath: "/private/tmp/Kaname.app"),
            bundleDigest: String(repeating: "a", count: 64)
        )
        let idleReceipt = KanameUpdateReceipt(status: .idle, detail: "Idle", updatedAtUnixMillis: 0)

        let available = KanameUpdateNoticeProjection.notice(
            channel: .stable,
            discoveryStatus: .available,
            availableUpdate: update,
            receipt: idleReceipt
        )
        #expect(available?.phase == .available)
        #expect(available?.isDismissible == true)
        #expect(KanameUpdateNoticeProjection.isVisible(available, dismissedIdentity: nil))
        #expect(!KanameUpdateNoticeProjection.isVisible(available, dismissedIdentity: update.identity))

        let retry = KanameUpdateNoticeProjection.notice(
            channel: .stable,
            discoveryStatus: .failed,
            availableUpdate: update,
            receipt: idleReceipt
        )
        #expect(retry?.phase == .retry)
        #expect(retry?.isDismissible == false)
        #expect(KanameUpdateNoticeProjection.isVisible(retry, dismissedIdentity: update.identity))

        let preparing = KanameUpdateNoticeProjection.notice(
            channel: .stable,
            discoveryStatus: .verifying,
            availableUpdate: update,
            receipt: idleReceipt
        )
        #expect(preparing?.phase == .preparing)
        #expect(preparing?.isDismissible == false)

        let stagedReceipt = KanameUpdateReceipt(
            status: .staged,
            version: "0.17.1",
            build: "30",
            bundleDigest: String(repeating: "b", count: 64),
            detail: "Ready",
            updatedAtUnixMillis: 2
        )
        let ready = KanameUpdateNoticeProjection.notice(
            channel: .stable,
            discoveryStatus: .staged,
            availableUpdate: update,
            receipt: stagedReceipt
        )
        #expect(ready?.phase == .readyToInstall)
        #expect(ready?.version == "0.17.1")
        #expect(ready?.build == "30")
        #expect(ready?.isDismissible == false)

        #expect(KanameUpdateNoticeProjection.notice(
            channel: .candidate,
            discoveryStatus: .available,
            availableUpdate: update,
            receipt: idleReceipt
        ) == nil)
        #expect(KanameUpdateNoticeProjection.notice(
            channel: .stable,
            discoveryStatus: .deferred,
            availableUpdate: update,
            receipt: idleReceipt
        ) == nil)
    }

    @Test
    func automaticUpdateCheckPolicyUsesFourMinuteBoundaryAndRecoversFromClockRollback() {
        #expect(KanameUpdateAutomaticCheckPolicy.startupDelaySeconds == 15)
        #expect(KanameUpdateAutomaticCheckPolicy.intervalSeconds == 240)
        #expect(KanameUpdateAutomaticCheckPolicy.permitsCheck(lastAttemptAtUnixMillis: nil, nowUnixMillis: 1))
        #expect(!KanameUpdateAutomaticCheckPolicy.permitsCheck(lastAttemptAtUnixMillis: 1_000, nowUnixMillis: 240_999))
        #expect(KanameUpdateAutomaticCheckPolicy.permitsCheck(lastAttemptAtUnixMillis: 1_000, nowUnixMillis: 241_000))
        #expect(KanameUpdateAutomaticCheckPolicy.permitsCheck(lastAttemptAtUnixMillis: 5_000, nowUnixMillis: 4_000))
    }

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "kaname-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func release(
        for bundle: URL,
        relativePath: String,
        notes: String = "Dogfood update"
    ) throws -> KanameLocalDogfoodCatalogDocument.Release {
        KanameLocalDogfoodCatalogDocument.Release(
            version: try #require(Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
            build: try #require(Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
            bundleIdentifier: "com.cyberlane.kaname.desktop",
            publishedAtUnixMillis: 1,
            releaseNotes: notes,
            minimumWorkspaceSchema: 1,
            maximumWorkspaceSchema: KanameDesktopStateSchema.currentVersion,
            artifactRelativePath: relativePath,
            bundleDigest: try KanameUpdateCoordinator.bundleDigest(at: bundle)
        )
    }

    private func writeCatalog(
        _ releases: [KanameLocalDogfoodCatalogDocument.Release],
        environment: KanameDesktopEnvironment
    ) throws {
        try FileManager.default.createDirectory(at: environment.dogfoodUpdateDirectory, withIntermediateDirectories: true)
        let document = KanameLocalDogfoodCatalogDocument(
            schemaVersion: 1,
            channel: "stable",
            generatedAtUnixMillis: 1,
            releases: releases
        )
        try JSONEncoder().encode(document).write(to: environment.dogfoodUpdateCatalogURL, options: .atomic)
    }

    private func makeBundle(root: URL, name: String, version: String, build: String) throws -> URL {
        let bundle = root.appending(path: "\(name).app", directoryHint: .isDirectory)
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: contents.appending(path: "MacOS", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.cyberlane.kaname.desktop",
            "CFBundleExecutable": "Kaname",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return bundle
    }
}
