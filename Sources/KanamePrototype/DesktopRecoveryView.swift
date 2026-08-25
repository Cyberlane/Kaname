import AppKit
import KanameDesignSystem
import KanameDesktop
import KanamePrototypeUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DesktopRecoveryViewModel: ObservableObject {
    @Published var selectedResetBackup: URL?
    @Published var resetConfirmation = ""
    @Published var message: String?
    @Published var isShowingReset = false

    private let backupType = UTType(exportedAs: "com.cyberlane.kaname.backup")

    func exportBackup(model: DesktopAppModel) {
        let panel = NSSavePanel()
        panel.title = "Export a private Kaname backup"
        panel.prompt = "Export Backup"
        panel.nameFieldStringValue = "Kaname Workspace.kanamebackup"
        panel.allowedContentTypes = [backupType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try model.exportRecoveryBackup(to: url)
            selectedResetBackup = url
            message = "Backup verified and saved. Kaname did not upload it."
        } catch {
            message = error.localizedDescription
        }
    }

    func restorePrevious(model: DesktopAppModel) {
        do {
            try model.restorePreviousWorkspace()
            message = "The previous workspace was verified and restored."
        } catch {
            message = error.localizedDescription
        }
    }

    func chooseAndRestore(model: DesktopAppModel) {
        guard let url = chooseBackup(prompt: "Restore Verified Backup") else { return }
        do {
            try model.restoreWorkspace(fromVerifiedBackup: url)
            message = "The selected backup was verified and restored."
        } catch {
            message = error.localizedDescription
        }
    }

    func chooseResetBackup(model: DesktopAppModel) {
        guard let url = chooseBackup(prompt: "Use Verified Backup") else { return }
        do {
            _ = try DesktopRecoveryService().validateBackup(at: url)
            selectedResetBackup = url
            resetConfirmation = ""
            message = "Backup verified. Type RESET only when you are ready to replace the workspace."
        } catch {
            selectedResetBackup = nil
            message = error.localizedDescription
        }
    }

    func reset(model: DesktopAppModel) {
        guard resetConfirmation == "RESET", let selectedResetBackup else {
            message = "Select a verified backup and type RESET exactly."
            return
        }
        do {
            _ = try model.resetWorkspace(verifiedBackupAt: selectedResetBackup)
            resetConfirmation = ""
            isShowingReset = false
            message = "A fresh workspace was created. Your verified backup was retained."
        } catch {
            message = error.localizedDescription
        }
    }

    private func chooseBackup(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Kaname backup"
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [backupType]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct DesktopRecoveryCenter: View {
    @ObservedObject var model: DesktopAppModel
    let inspectDiagnostics: () -> Void
    @StateObject private var recovery = DesktopRecoveryViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Nord.polarNight0.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    recoverySummary
                    restoreActions
                    resetSection
                    privacyNote
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(36)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: recovery.isShowingReset)
        .accessibilityElement(children: .contain)
        .onChange(of: recovery.message) { message in
            guard let message else { return }
            KanameAccessibilityAnnouncement.post(message)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recovery Center", systemImage: "externaldrive.badge.exclamationmark")
                .font(.largeTitle.bold())
                .foregroundStyle(Nord.snowStorm0)
            Text("Kaname preserved the workspace it could not safely open.\nEditing, providers, and connected services are paused; verified backup and diagnostics actions remain available.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var recoverySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(reasonTitle, systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(Nord.auroraYellow)
            Text(reasonDetail)
                .foregroundStyle(.secondary)
            if model.recoveryStatus?.quarantineCreated == true {
                Label("The original bytes were copied into Kaname’s private Recovery folder.", systemImage: "checkmark.seal")
                    .foregroundStyle(Nord.auroraGreen)
            }
            if let message = recovery.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14))
    }

    private var restoreActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recover without losing the preserved original")
                .font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { restoreActionButtons }
                VStack(alignment: .leading, spacing: 8) { restoreActionButtons }
            }
            Text("Restore validates the manifest, file sizes, and SHA-256 digests before replacing workspace state.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var restoreActionButtons: some View {
        Button("Export Backup…") { recovery.exportBackup(model: model) }
            .buttonStyle(.borderedProminent)
        if model.recoveryStatus?.previousWorkspaceAvailable == true {
            Button("Restore Previous") { recovery.restorePrevious(model: model) }
                .buttonStyle(.bordered)
        }
        Button("Restore Backup…") { recovery.chooseAndRestore(model: model) }
            .buttonStyle(.bordered)
        Button("Inspect Diagnostics…", systemImage: "doc.text.magnifyingglass") {
            inspectDiagnostics()
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var resetSection: some View {
        Divider()
        VStack(alignment: .leading, spacing: 12) {
            Button(recovery.isShowingReset ? "Hide reset options" : "I still need a fresh workspace…") {
                recovery.isShowingReset.toggle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Nord.auroraRed)

            if recovery.isShowingReset {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Factory reset is available only after Kaname verifies a backup. The backup and recovery receipts remain on disk.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(recovery.selectedResetBackup == nil ? "Choose Verified Backup…" : "Change Backup…") {
                            recovery.chooseResetBackup(model: model)
                        }
                        if let selected = recovery.selectedResetBackup {
                            Text(selected.lastPathComponent)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        }
                    }
                    TextField("Type RESET to confirm", text: $recovery.resetConfirmation)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .accessibilityHint("Enter the uppercase word RESET after selecting a verified backup")
                    Button("Create Fresh Workspace", role: .destructive) {
                        recovery.reset(model: model)
                    }
                    .disabled(recovery.selectedResetBackup == nil || recovery.resetConfirmation != "RESET")
                }
                .padding(16)
                .background(Nord.auroraRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var privacyNote: some View {
        Label("Recovery data stays local. Kaname never uploads backups, diagnostics, or crash information automatically.", systemImage: "hand.raised.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var reasonTitle: String {
        switch model.recoveryStatus?.reason {
        case .unreadableState: "Workspace data could not be read"
        case .unsupportedStateVersion: "This workspace was written by a newer Kaname"
        case .migrationFailed: "Workspace migration could not be verified"
        case .initialPersistenceFailed: "A safe writable workspace could not be created"
        case .runtimeRollbackUnverified: "Runtime recovery could not be verified"
        case nil: "Workspace recovered"
        }
    }

    private var reasonDetail: String {
        if let version = model.recoveryStatus?.detectedStateSchemaVersion {
            return "Detected state schema version \(version). No original workspace data has been overwritten."
        }
        return "No original workspace data has been overwritten. Export a backup before choosing restore or reset."
    }
}
