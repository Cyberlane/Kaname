import KanameDesktop
import KanamePrototypeUI
import SwiftUI
import KanameDesignSystem

struct DesktopAutomaticBackupSettings: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var backup: DesktopAutomaticBackupViewModel
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var passphrase = ""
    @State private var passphraseConfirmation = ""

    var body: some View {
        VStack(spacing: 14) {
            SettingsSection(title: "Automatic encrypted backups", symbol: "externaldrive.badge.icloud") {
                Toggle("Back up Kaname automatically", isOn: Binding(
                    get: { backup.configuration.enabled },
                    set: { backup.setEnabled($0) }
                ))
                Picker("Destination", selection: configurationBinding(\.destination)) {
                    ForEach(DesktopBackupDestination.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                destinationFields
                HStack {
                    Button("Test destination", systemImage: "checkmark.shield") { backup.testConnection() }
                        .disabled(backup.isBusy || !backup.secretsConfigured)
                    if backup.configuration.verifiedDestinationDigest == backup.configuration.destinationDigest {
                        Label("Verified", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(KanameColor.success)
                    } else {
                        Text("Test this exact destination before enabling backups.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if backup.isBusy { ProgressView().controlSize(.small) }
                }
            }

            SettingsSection(title: "Encryption and credentials", symbol: "key.fill") {
                if backup.configuration.destination != .localFolder {
                    SecureField("Access-key ID", text: $accessKeyID)
                        .textContentType(.username)
                    SecureField("Secret access key", text: $secretAccessKey)
                        .textContentType(.password)
                }
                SecureField("Backup encryption passphrase", text: $passphrase)
                SecureField("Confirm encryption passphrase", text: $passphraseConfirmation)
                HStack {
                    Button(backup.secretsConfigured ? "Replace saved credentials" : "Save credentials") {
                        backup.saveSecrets(
                            accessKeyID: accessKeyID,
                            secretAccessKey: secretAccessKey,
                            passphrase: passphrase
                        )
                        accessKeyID = ""
                        secretAccessKey = ""
                        passphrase = ""
                        passphraseConfirmation = ""
                    }
                    .disabled(!passphraseIsValid)
                    if backup.secretsConfigured {
                        Label("Stored in this Mac's device-only Keychain", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", role: .destructive) { backup.removeSecrets() }
                    }
                }
                Text("Kaname never stores the passphrase or S3 secret in workspace state. Keep the passphrase in your own password manager; losing both this Mac and the passphrase makes remote backups unrecoverable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(title: "Schedule and retention", symbol: "calendar.badge.clock") {
                Stepper(
                    "Back up every \(backup.configuration.frequencyHours) hour\(backup.configuration.frequencyHours == 1 ? "" : "s")",
                    value: configurationBinding(\.frequencyHours),
                    in: 1...168
                )
                Stepper(
                    "Keep generations for \(backup.configuration.retentionDays) days",
                    value: configurationBinding(\.retentionDays),
                    in: 7...365,
                    step: 7
                )
                Text("Kaname always retains at least the three newest generations. Retention removes only older objects under the configured Kaname prefix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(title: "Recoverability", symbol: "lifepreserver.fill") {
                statusRows
                ViewThatFits(in: .horizontal) {
                    HStack {
                        backupButtons
                    }
                    VStack(alignment: .leading) {
                        backupButtons
                    }
                }
                .disabled(backup.isBusy || !backup.secretsConfigured)
                if let message = backup.message {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            BoundaryCallout(
                title: "One coherent generation",
                detail: "Kaname seals workspace and runtime artifacts together, encrypts them before upload, verifies the uploaded digest, and restores only through a staged verified .kanamebackup. R2 and S3 are destinations, not sources of application truth."
            )
        }
    }

    @ViewBuilder private var backupButtons: some View {
        Button("Back up now", systemImage: "arrow.up.doc") { backup.backupNow(model: model) }
            .buttonStyle(.borderedProminent)
        Button("Verify latest", systemImage: "checkmark.seal") { backup.verifyLatest() }
        Button("Download latest…", systemImage: "arrow.down.doc") { backup.downloadLatest() }
    }

    @ViewBuilder
    private var destinationFields: some View {
        switch backup.configuration.destination {
        case .localFolder:
            HStack {
                Button("Choose folder…", systemImage: "folder") { backup.chooseLocalFolder() }
                Text(backup.configuration.localFolderPath.isEmpty ? "No folder selected" : backup.configuration.localFolderPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(backup.configuration.localFolderPath)
            }
        case .cloudflareR2, .s3Compatible:
            TextField("HTTPS S3 endpoint", text: configurationBinding(\.endpoint))
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Bucket", text: configurationBinding(\.bucket))
                TextField("Region", text: configurationBinding(\.region))
                    .frame(maxWidth: 150)
            }
            .textFieldStyle(.roundedBorder)
            if backup.configuration.destination == .cloudflareR2 {
                Text("Use https://<account-id>.r2.cloudflarestorage.com and region auto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        LabeledContent("Object prefix") {
            TextField("Private prefix", text: configurationBinding(\.prefix))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        LabeledContent("Automatic backups", value: backup.configuration.enabled ? "On" : "Off")
        if let value = backup.configuration.lastAttemptAtUnixMillis {
            LabeledContent("Last attempted", value: formatted(value))
        }
        if let value = backup.configuration.lastSuccessAtUnixMillis {
            LabeledContent("Last successful", value: formatted(value))
        } else {
            LabeledContent("Last successful", value: "Never")
        }
        if let value = backup.configuration.lastVerifiedAtUnixMillis {
            LabeledContent("Last fully verified", value: formatted(value))
        }
        if let value = backup.configuration.nextBackupAtUnixMillis {
            LabeledContent("Next scheduled", value: formatted(value))
        }
        if let bytes = backup.configuration.lastObjectByteCount {
            LabeledContent("Latest encrypted size", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if let failure = backup.configuration.lastFailureSummary {
            LabeledContent("Needs attention") {
                Text(failure).foregroundStyle(KanameColor.warning).textSelection(.enabled)
            }
        }
    }

    private var passphraseIsValid: Bool {
        let normalized = passphrase.precomposedStringWithCompatibilityMapping
        return normalized.utf8.count >= 12
            && normalized.utf8.count <= 1_024
            && passphraseConfirmation.precomposedStringWithCompatibilityMapping == normalized
            && (backup.configuration.destination == .localFolder
                || (!accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    private func configurationBinding<Value>(_ keyPath: WritableKeyPath<DesktopAutomaticBackupConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { backup.configuration[keyPath: keyPath] },
            set: { value in backup.updateConfiguration { $0[keyPath: keyPath] = value } }
        )
    }

    private func formatted(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}
