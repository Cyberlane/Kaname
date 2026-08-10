import AppKit
import Foundation
import KanamePrototypeUI
import SwiftUI
import UniformTypeIdentifiers

struct DesktopDiagnosticsInspector: View {
    let report: String
    let dismiss: () -> Void
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Inspect redacted diagnostics", systemImage: "lifepreserver.fill")
                    .font(.title2.bold())
                Text("Review the complete file before you copy, export, or choose to share it. Kaname never uploads diagnostics or crash information automatically.")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Complete redacted diagnostics report")

            if let message {
                Label(message, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Counts and health states only — no prompts, messages, paths, account names, tokens, or credentials.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(Nord.auroraGreen)
                Spacer()
                Button("Copy") { copyReport() }
                Button("Export…") { exportReport() }
                Button("Done", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 760, minHeight: 480, idealHeight: 620)
        .accessibilityElement(children: .contain)
        .onExitCommand(perform: dismiss)
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        message = "Copied after review."
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.title = "Export redacted Kaname diagnostics"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Kaname Redacted Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(report.utf8).write(to: url, options: .atomic)
            message = "Exported locally. Nothing was uploaded."
        } catch {
            message = error.localizedDescription
        }
    }
}
