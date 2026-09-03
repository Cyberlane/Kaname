import AppKit
import Foundation
import KanameDesktop
import KanamePrototypeUI
import SwiftUI
import UniformTypeIdentifiers
import KanameDesignSystem

struct DesktopDiagnosticsInspector: View {
    let dismiss: () -> Void
    @State private var inspection: DesktopSupportBundleInspection
    @State private var feedback: Feedback?

    init(report: String, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        _inspection = State(initialValue: DesktopSupportBundleInspection(report: report))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Inspect redacted diagnostics", systemImage: "lifepreserver.fill")
                    .font(.title2.bold())
                Text("Review the complete file before you copy, export, or choose to share it. Kaname never uploads diagnostics or crash information automatically.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Inspected SHA-256")
                            .font(.caption.bold())
                        Text(inspection.sha256)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer()
                        Text("\(inspection.byteCount.formatted()) bytes")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if inspection.isValid {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(inspection.redactionCounts, id: \.category) { item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.category.label)
                                        .font(.caption)
                                    Spacer(minLength: 8)
                                    Text(item.count.formatted())
                                        .font(.caption.monospacedDigit().bold())
                                }
                            }
                        }
                    } else {
                        Label(
                            "This snapshot is malformed. Close it and generate a new inspection before copying or exporting.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(KanameColor.danger)
                    }
                }
            } label: {
                Label("Redaction summary from these exact bytes", systemImage: "checkmark.shield")
            }

            ScrollView {
                Text(inspectedReport)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Complete redacted diagnostics report")

            if let feedback {
                Label(
                    feedback.message,
                    systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle"
                )
                    .font(.caption)
                    .foregroundStyle(feedback.isError ? KanameColor.danger : KanameColor.success)
            }

            HStack {
                Label("Counts and health states only — no prompts, messages, paths, account names, tokens, or credentials.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(KanameColor.success)
                Spacer()
                Button("Copy") { copyReport() }
                    .disabled(!inspection.isValid)
                Button("Export…") { exportReport() }
                    .disabled(!inspection.isValid)
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

    private var inspectedReport: String {
        (try? inspection.validatedString()) ?? "The inspected diagnostics snapshot is unavailable."
    }

    private func copyReport() {
        do {
            let report = try inspection.validatedString()
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(report, forType: .string) else {
                throw DesktopDiagnosticsInspectorError.copyFailed
            }
            feedback = Feedback(
                message: "Copied inspected bundle \(inspection.sha256.prefix(12))… after review.",
                isError: false
            )
        } catch {
            feedback = Feedback(message: error.localizedDescription, isError: true)
        }
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.title = "Export redacted Kaname diagnostics"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Kaname Redacted Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let digest = try inspection.writeValidated(to: url)
            feedback = Feedback(
                message: "Exported inspected bundle \(digest.prefix(12))… locally. Nothing was uploaded.",
                isError: false
            )
        } catch {
            feedback = Feedback(message: error.localizedDescription, isError: true)
        }
    }

    private struct Feedback {
        let message: String
        let isError: Bool
    }

    private enum DesktopDiagnosticsInspectorError: Error, LocalizedError {
        case copyFailed

        var errorDescription: String? {
            "The inspected diagnostics could not be copied. Nothing was placed on the clipboard."
        }
    }
}
