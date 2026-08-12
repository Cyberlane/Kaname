import AppKit
import Foundation
import KanameConnectivity
import KanameDesktop
import UniformTypeIdentifiers

@MainActor
final class DesktopAutomaticBackupViewModel: ObservableObject {
    @Published private(set) var configuration: DesktopAutomaticBackupConfiguration
    @Published private(set) var isBusy = false
    @Published private(set) var secretsConfigured = false
    @Published var message: String?

    private let configurationStore: FileDesktopAutomaticBackupConfigurationStore
    private let secretStore: any DesktopAutomaticBackupSecretStoring
    private let service = DesktopAutomaticBackupService()
    private var schedulerTask: Task<Void, Never>?
    private var secretStatusTask: Task<Void, Never>?
    private var secretStatusRevision = 0

    init(environment: KanameDesktopEnvironment = .current) {
        configurationStore = FileDesktopAutomaticBackupConfigurationStore(
            fileURL: environment.desktopDirectory.appendingPathComponent("automatic-backup.json")
        )
        secretStore = KeychainDesktopAutomaticBackupSecretStore(
            service: "\(environment.bundleIdentifier).automatic-backup"
        )
        configuration = (try? configurationStore.load()) ?? .init()
        secretsConfigured = false
    }

    deinit {
        schedulerTask?.cancel()
        secretStatusTask?.cancel()
    }

    func start(model: DesktopAppModel) {
        loadSecretStatusIfNeeded()
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self, weak model] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, let model, self.configuration.enabled,
                      !self.isBusy,
                      (self.configuration.nextBackupAtUnixMillis ?? Int64.max) <= Self.nowMillis else { continue }
                self.backupNow(model: model, automatic: true)
            }
        }
        if configuration.enabled,
           (configuration.nextBackupAtUnixMillis ?? 0) <= Self.nowMillis {
            backupNow(model: model, automatic: true)
        }
    }

    func updateConfiguration(_ change: (inout DesktopAutomaticBackupConfiguration) -> Void) {
        var updated = configuration
        let previousDigest = updated.destinationDigest
        change(&updated)
        if updated.destinationDigest != previousDigest {
            updated.enabled = false
            updated.verifiedDestinationDigest = nil
        }
        persist(updated)
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose automatic backup folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.showsHiddenFiles = false
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else {
            message = "Choose a real local folder rather than a file, alias, or symbolic link."
            return
        }
        updateConfiguration {
            $0.destination = .localFolder
            $0.localFolderPath = url.standardizedFileURL.path
        }
        message = "Folder selected. Test it before enabling automatic backups."
    }

    func saveSecrets(accessKeyID: String, secretAccessKey: String, passphrase: String) {
        let access = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassphrase = passphrase.precomposedStringWithCompatibilityMapping
        guard normalizedPassphrase.utf8.count >= 12, normalizedPassphrase.utf8.count <= 1_024 else {
            message = "Use a backup encryption passphrase containing at least 12 characters."
            return
        }
        if configuration.destination != .localFolder, (access.isEmpty || secret.isEmpty) {
            message = "Enter both the access-key ID and secret access key for this remote destination."
            return
        }
        do {
            try secretStore.save(.init(
                accessKeyID: access,
                secretAccessKey: secret,
                encryptionPassphrase: normalizedPassphrase
            ))
            secretStatusRevision += 1
            secretsConfigured = true
            var updated = configuration
            updated.enabled = false
            updated.verifiedDestinationDigest = nil
            persist(updated)
            message = "Credentials and the encryption passphrase were saved in the device-only Keychain. Test the destination before enabling backups."
        } catch {
            message = error.localizedDescription
        }
    }

    func removeSecrets() {
        do {
            try secretStore.delete()
            secretStatusRevision += 1
            secretsConfigured = false
            var updated = configuration
            updated.enabled = false
            updated.verifiedDestinationDigest = nil
            persist(updated)
            message = "Backup credentials were removed from the Keychain. Existing encrypted backups were not changed."
        } catch {
            message = error.localizedDescription
        }
    }

    func testConnection() {
        guard !isBusy else { return }
        isBusy = true
        message = "Testing the private destination…"
        Task {
            defer { isBusy = false }
            do {
                let (validated, secrets, transport) = try preparedTransport()
                try await transport.testConnection(prefix: validated.prefix)
                var updated = validated
                updated.verifiedDestinationDigest = updated.destinationDigest
                updated.lastFailureSummary = nil
                persist(updated)
                _ = secrets
                message = "Destination verified. No backup data was uploaded."
            } catch {
                var updated = configuration
                updated.enabled = false
                updated.verifiedDestinationDigest = nil
                updated.lastFailureSummary = Self.safeFailure(error)
                persist(updated)
                message = error.localizedDescription
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard configuration.verifiedDestinationDigest == configuration.destinationDigest,
                  secretsConfigured,
                  (try? configuration.validated()) != nil else {
                message = "Save encryption credentials and test this exact destination before enabling automatic backups."
                return
            }
        }
        var updated = configuration
        updated.enabled = enabled
        persist(updated)
        message = enabled
            ? "Automatic encrypted backups are enabled. Kaname will wait for active work to finish before sealing a generation."
            : "Automatic backups are off. Existing local or remote backups were retained."
    }

    func backupNow(model: DesktopAppModel, automatic: Bool = false) {
        guard !isBusy else { return }
        isBusy = true
        var attempted = configuration
        attempted.lastAttemptAtUnixMillis = Self.nowMillis
        persist(attempted)
        if !automatic { message = "Creating one coherent encrypted backup generation…" }

        Task {
            let stagingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("kaname-automatic-backup-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stagingRoot) }
            defer { isBusy = false }
            do {
                let (validated, secrets, transport) = try preparedTransport()
                try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let bundle = stagingRoot.appendingPathComponent("generation.kanamebackup", isDirectory: true)
                do {
                    _ = try model.exportRecoveryBackup(to: bundle)
                } catch DesktopModelRecoveryError.activeRuntimeWork {
                    throw DesktopAutomaticBackupError.activeRuntimeWork
                }
                let passphrase = secrets.encryptionPassphrase
                let artifact = try await Task.detached(priority: .utility) {
                    try DesktopEncryptedBackupBundleCodec.seal(bundleURL: bundle, passphrase: passphrase)
                }.value
                let key = service.objectKey(configuration: validated, artifact: artifact)
                try await transport.put(key: key, data: artifact.data, sha256: artifact.sha256)
                var updated = validated
                updated.lastSuccessAtUnixMillis = Self.nowMillis
                updated.lastVerifiedAtUnixMillis = Self.nowMillis
                updated.lastObjectKey = key
                updated.lastObjectByteCount = Int64(artifact.data.count)
                updated.lastFailureSummary = nil
                persist(updated)
                do {
                    try await service.enforceRetention(transport: transport, configuration: updated, now: Date())
                } catch {
                    updated.lastFailureSummary = "Backup verified; retention needs attention: \(Self.safeFailure(error))"
                    persist(updated)
                    message = "Encrypted backup verified. Retention cleanup needs attention."
                    return
                }
                message = "Encrypted backup verified · \(ByteCountFormatter.string(fromByteCount: Int64(artifact.data.count), countStyle: .file))."
            } catch {
                var updated = configuration
                updated.lastFailureSummary = Self.safeFailure(error)
                persist(updated)
                message = automatic && error is DesktopAutomaticBackupError
                    ? "Automatic backup is waiting for a safe opportunity."
                    : error.localizedDescription
            }
        }
    }

    func verifyLatest() {
        guard !isBusy else { return }
        isBusy = true
        message = "Downloading and verifying the latest encrypted generation…"
        Task {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("kaname-backup-verify-\(UUID().uuidString).kanamebackup", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            defer { isBusy = false }
            do {
                let (validated, secrets, transport) = try preparedTransport()
                let object = try await service.latestObject(transport: transport, configuration: validated)
                let data = try await transport.get(key: object.key)
                _ = try await Task.detached(priority: .utility) {
                    try DesktopEncryptedBackupBundleCodec.open(
                        data,
                        passphrase: secrets.encryptionPassphrase,
                        destination: staging
                    )
                }.value
                var updated = validated
                updated.lastVerifiedAtUnixMillis = Self.nowMillis
                updated.lastFailureSummary = nil
                persist(updated)
                message = "Latest backup downloaded, decrypted, and fully verified without replacing live state."
            } catch {
                var updated = configuration
                updated.lastFailureSummary = Self.safeFailure(error)
                persist(updated)
                message = error.localizedDescription
            }
        }
    }

    func downloadLatest() {
        let panel = NSSavePanel()
        panel.title = "Download and decrypt latest Kaname backup"
        panel.prompt = "Download Verified Backup"
        panel.nameFieldStringValue = "Kaname Remote Backup.kanamebackup"
        panel.allowedContentTypes = [UTType(exportedAs: "com.cyberlane.kaname.backup")]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard !isBusy else { return }
        isBusy = true
        message = "Downloading, decrypting, and verifying the latest backup…"
        Task {
            defer { isBusy = false }
            do {
                let (validated, secrets, transport) = try preparedTransport()
                let object = try await service.latestObject(transport: transport, configuration: validated)
                let data = try await transport.get(key: object.key)
                _ = try await Task.detached(priority: .utility) {
                    try DesktopEncryptedBackupBundleCodec.open(
                        data,
                        passphrase: secrets.encryptionPassphrase,
                        destination: destination
                    )
                }.value
                var updated = validated
                updated.lastVerifiedAtUnixMillis = Self.nowMillis
                persist(updated)
                message = "Downloaded a verified local .kanamebackup. Restoring remains a separate Recovery Center action."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func preparedTransport() throws -> (
        DesktopAutomaticBackupConfiguration,
        DesktopAutomaticBackupSecrets,
        any DesktopBackupObjectTransport
    ) {
        let validated = try configuration.validated()
        guard let secrets = try secretStore.load(), secrets.encryptionPassphrase.utf8.count >= 12 else {
            throw DesktopAutomaticBackupError.credentialsUnavailable
        }
        return (validated, secrets, try service.transport(configuration: validated, secrets: secrets))
    }

    private func loadSecretStatusIfNeeded() {
        guard secretStatusTask == nil else { return }
        let store = secretStore
        let revision = secretStatusRevision
        secretStatusTask = Task { [weak self] in
            let configured = await Task.detached(priority: .utility) {
                ((try? store.load()) ?? nil) != nil
            }.value
            guard !Task.isCancelled, let self, revision == self.secretStatusRevision else { return }
            self.secretsConfigured = configured
        }
    }

    private func persist(_ updated: DesktopAutomaticBackupConfiguration) {
        do {
            try configurationStore.save(updated)
            configuration = updated
        } catch {
            message = error.localizedDescription
        }
    }

    private static var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    private static func safeFailure(_ error: Error) -> String {
        let value = error.localizedDescription
        return value.utf8.count <= 512 ? value : String(value.prefix(512))
    }
}
