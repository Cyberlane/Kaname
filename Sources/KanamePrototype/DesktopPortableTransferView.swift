import AppKit
import KanameDesktop
import KanamePrototypeUI
import SwiftUI
import UniformTypeIdentifiers
import KanameDesignSystem

struct DesktopImportReview: Identifiable {
    let id = UUID()
    let threadID: String
    let preview: DesktopImportPreview
}

@MainActor
final class DesktopPortableTransferViewModel: ObservableObject {
    @Published var importReview: DesktopImportReview?
    @Published var message: String?

    @discardableResult
    func chooseImport(threadID: String?) -> Bool {
        guard let threadID else {
            message = "Open a conversation before importing files. Nothing was read."
            return false
        }
        let panel = NSOpenPanel()
        panel.title = "Import local files into this draft"
        panel.prompt = "Review files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText, .sourceCode, .json, .xml, .yaml]
        guard panel.runModal() == .OK else { return false }
        return prepareImport(urls: panel.urls, threadID: threadID)
    }

    @discardableResult
    func prepareImport(urls: [URL], threadID: String?) -> Bool {
        guard let threadID else {
            message = "Open a conversation before dropping files. Nothing was read."
            return false
        }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        do {
            importReview = DesktopImportReview(
                threadID: threadID,
                preview: try DesktopImportExportService.previewImport(urls: urls)
            )
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func addImportToDraft(model: DesktopAppModel) {
        guard let review = importReview else { return }
        let existing = model.composerDraft(threadID: review.threadID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = existing.isEmpty
            ? review.preview.composerDraft
            : existing + "\n\n" + review.preview.composerDraft
        if model.updateComposerDraft(threadID: review.threadID, body: body) {
            message = "Added \(review.preview.files.count) local file\(review.preview.files.count == 1 ? "" : "s") to the draft. Review the text before sending."
            importReview = nil
        } else {
            message = model.persistenceError ?? "The imported text could not be saved to the draft."
        }
    }

    func export(thread: DesktopThread?, project: DesktopProject?, model: DesktopAppModel) {
        do {
            let document: DesktopPortableDocument
            if let thread {
                document = try DesktopImportExportService.exportConversation(
                    thread,
                    projectName: thread.projectID.flatMap { model.project(id: $0)?.name }
                )
            } else if let project {
                document = try DesktopImportExportService.exportProject(project)
            } else {
                throw DesktopImportExportError.emptyDocument
            }
            let panel = NSSavePanel()
            panel.title = "Export current Kaname context"
            panel.prompt = "Export"
            panel.nameFieldStringValue = document.suggestedFilename
            let markdownType = UTType(filenameExtension: "md") ?? .plainText
            panel.allowedContentTypes = document.kind == .conversationMarkdown ? [markdownType] : [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try document.data.write(to: url, options: .atomic)
            message = "Exported the selected \(document.kind == .conversationMarkdown ? "conversation" : "project") locally."
        } catch {
            message = error.localizedDescription
        }
    }
}

struct DesktopImportReviewSheet: View {
    @ObservedObject var transfer: DesktopPortableTransferViewModel
    @ObservedObject var model: DesktopAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let review = transfer.importReview {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Review local file import", systemImage: "doc.badge.plus")
                        .font(.title2.weight(.bold))
                    Text("Kaname has read only the files you selected. Their text will be added to the composer as an unsent draft.")
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(review.preview.files) { file in
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(KanameColor.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.displayName).font(.body.weight(.semibold))
                                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file)) · SHA-256 \(file.sha256.prefix(12))")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(KanameColor.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .frame(maxHeight: 260)

                Label("Adding files does not contact a provider. Sending the resulting composer draft remains a separate action.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(KanameColor.success)

                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(review.preview.totalByteCount), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        transfer.importReview = nil
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Add to Draft") {
                        transfer.addImportToDraft(model: model)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(minWidth: 520, idealWidth: 620, minHeight: 380)
            .accessibilityElement(children: .contain)
        }
    }
}
