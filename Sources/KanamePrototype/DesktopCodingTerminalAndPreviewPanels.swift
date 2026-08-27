import KanameConnectivity
import KanameDesktop
import KanameDesignSystem
import SwiftUI
#if os(macOS)
@preconcurrency import WebKit
#endif

struct DesktopCodingTerminalPanel: View {
    @ObservedObject var model: DesktopAppModel
    let thread: DesktopThread
    @State private var commandDraft = ""
    @State private var isRunning = false
    @State private var message: String?

    private var terminal: DesktopCodingTerminalRecord? {
        model.snapshot.operations.codingTerminals
            .filter { $0.threadID == thread.id && $0.state != .closed }
            .max { $0.updatedAtUnixMillis < $1.updatedAtUnixMillis }
    }

    private var worktree: DesktopWorktreeRecord? {
        model.snapshot.operations.worktrees
            .filter { $0.threadID == thread.id && $0.state != .removed }
            .max { $0.updatedAtUnixMillis < $1.updatedAtUnixMillis }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(terminal?.label ?? "Terminal", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                Text(terminal?.cwd ?? worktree?.worktreePath ?? "No worktree cwd yet")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text((terminal?.state ?? .idle).label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Nord.frost1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Nord.polarNight1)

            Divider()

            ScrollView {
                Text(terminal?.scrollbackExcerpt.isEmpty == false
                    ? terminal!.scrollbackExcerpt
                    : "Phase A terminal is read/attach oriented. Run a local command below; attach the excerpt from the composer when output is present.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(terminal?.hasAttachableExcerpt == true ? Color.primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Shell command (human-only)", text: $commandDraft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isRunning || worktree == nil)
                Button("Run") { runCommand() }
                    .disabled(isRunning || worktree == nil || commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Ensure terminal") { ensureTerminal() }
                    .disabled(worktree == nil)
            }
            .padding(12)
            if let message {
                Text(message).font(.caption2).foregroundStyle(Nord.auroraYellow).padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .background(Nord.polarNight0)
        .onAppear { ensureTerminal() }
    }

    private func ensureTerminal() {
        guard let worktree else { return }
        if terminal != nil { return }
        let service = DesktopCodingTerminalService()
        _Concurrency.Task {
            let record = await service.ensureDefaultTerminal(
                threadID: thread.id,
                cwd: worktree.worktreePath,
                worktreeID: worktree.id
            )
            model.upsertCodingTerminal(record)
        }
    }

    private func runCommand() {
        guard let worktree else { return }
        let command = commandDraft
        isRunning = true
        message = nil
        _Concurrency.Task {
            let service = DesktopCodingTerminalService()
            let base: DesktopCodingTerminalRecord
            if let terminal {
                base = terminal
            } else {
                base = await service.ensureDefaultTerminal(
                    threadID: thread.id,
                    cwd: worktree.worktreePath,
                    worktreeID: worktree.id
                )
            }
            do {
                let record = try await service.runCommand(command, updating: base)
                model.upsertCodingTerminal(record)
                commandDraft = ""
            } catch {
                message = error.localizedDescription
            }
            isRunning = false
        }
    }
}

struct DesktopCodingPreviewPanel: View {
    @ObservedObject var model: DesktopAppModel
    let thread: DesktopThread
    @State private var urlDraft = "http://127.0.0.1:5173"

    private var tab: DesktopCodingPreviewTabRecord? {
        model.snapshot.operations.codingPreviewTabs
            .filter { $0.threadID == thread.id && $0.state != .closed }
            .max { $0.updatedAtUnixMillis < $1.updatedAtUnixMillis }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Preview", systemImage: "safari")
                    .font(.caption.weight(.semibold))
                TextField("Local URL", text: $urlDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Open") { openPreview() }
                Button("Refresh") { openPreview() }
                    .disabled(tab == nil)
            }
            .padding(12)
            .background(Nord.polarNight1)

            Divider()

            if let tab, let url = URL(string: tab.url), CodingPreviewMCPGrant.isLocalPreviewURL(url) {
#if os(macOS)
                DesktopCodingPreviewWebView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
                Text("Preview is desktop-only.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
            } else {
                EmptyPanel(
                    symbol: "safari",
                    title: "No preview open",
                    detail: "Open a localhost or 127.0.0.1 URL. Curated MCP automation stays blocked until an explicit coding.preview_mcp_grant approval."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Nord.polarNight0)
    }

    private func openPreview() {
        guard let url = URL(string: urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              CodingPreviewMCPGrant.isLocalPreviewURL(url) else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let record = DesktopCodingPreviewTabRecord.make(
            id: tab?.id ?? "preview-\(thread.id)",
            threadID: thread.id,
            title: url.host ?? "Preview",
            url: url.absoluteString,
            state: .ready,
            updatedAtUnixMillis: now
        )
        model.upsertCodingPreviewTab(record)
    }
}

#if os(macOS)
private struct DesktopCodingPreviewWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
#endif
