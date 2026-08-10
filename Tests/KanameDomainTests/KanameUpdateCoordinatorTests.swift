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
