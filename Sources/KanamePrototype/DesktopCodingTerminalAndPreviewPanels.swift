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
    @State private var selectedTerminalID = DesktopCodingTerminalRecord.defaultTerminalID

    private var terminals: [DesktopCodingTerminalRecord] {
        model.snapshot.operations.codingTerminals
            .filter { $0.threadID == thread.id && $0.state != .closed }
            .sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }
    }

    private var terminal: DesktopCodingTerminalRecord? {
        terminals.first(where: { $0.id == selectedTerminalID }) ?? terminals.first
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
                if terminals.count > 1 {
                    Picker("Terminal", selection: $selectedTerminalID) {
                        ForEach(terminals) { record in
                            Text(record.label).tag(record.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
                Text(terminal?.cwd ?? worktree?.worktreePath ?? "No worktree cwd yet")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let pid = terminal?.processID {
                    Text("pid \(pid)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
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
                    : "Open an interactive PTY or run a bounded command. Attach the excerpt from the composer when output is present.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(terminal?.hasAttachableExcerpt == true ? Color.primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }

            if let ports = terminal?.discoveredPreviewPorts, !ports.isEmpty {
                Text("Preview ports: \(ports.map(String.init).joined(separator: ", "))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Nord.frost1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Shell command (human-only)", text: $commandDraft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isRunning || worktree == nil)
                Button("Run") { runCommand() }
                    .disabled(isRunning || worktree == nil || commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Open PTY") { openPTY() }
                    .disabled(isRunning || worktree == nil)
                Button("New") { addTerminal() }
                    .disabled(worktree == nil)
                Button("Scan ports") { scanPorts() }
                    .disabled(terminal?.processID == nil)
                Button("Ensure") { ensureTerminal() }
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
        let service = DesktopCodingTerminalService.shared
        _Concurrency.Task {
            let record = await service.ensureDefaultTerminal(
                threadID: thread.id,
                cwd: worktree.worktreePath,
                worktreeID: worktree.id
            )
            model.upsertCodingTerminal(record)
            selectedTerminalID = record.id
        }
    }

    private func addTerminal() {
        guard let worktree else { return }
        let service = DesktopCodingTerminalService.shared
        let id = "term-\(UUID().uuidString.lowercased().prefix(8))"
        _Concurrency.Task {
            let record = await service.createTerminal(
                id: id,
                threadID: thread.id,
                cwd: worktree.worktreePath,
                worktreeID: worktree.id,
                label: "Terminal \(terminals.count + 1)"
            )
            model.upsertCodingTerminal(record)
            selectedTerminalID = record.id
        }
    }

    private func openPTY() {
        guard let worktree else { return }
        isRunning = true
        message = nil
        _Concurrency.Task {
            let service = DesktopCodingTerminalService.shared
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
                let record = try await service.attachInteractive(updating: base) { chunk in
                    _Concurrency.Task { @MainActor in
                        if var current = model.snapshot.operations.codingTerminals.first(where: { $0.id == base.id }) {
                            current.scrollbackExcerpt = DesktopCodingTerminalService.boundedScrollback(
                                (current.scrollbackExcerpt) + chunk
                            )
                            if current.scrollbackExcerpt.utf8.count > DesktopCodingTerminalRecord.maximumExcerptBytes {
                                let data = Data(current.scrollbackExcerpt.utf8)
                                current.scrollbackExcerpt = String(
                                    decoding: data.suffix(DesktopCodingTerminalRecord.maximumExcerptBytes),
                                    as: UTF8.self
                                )
                            }
                            current.state = .running
                            current.updatedAtUnixMillis = Int64(Date().timeIntervalSince1970 * 1_000)
                            model.upsertCodingTerminal(current)
                        }
                    }
                }
                model.upsertCodingTerminal(record)
                selectedTerminalID = record.id
                message = "Interactive PTY attached (pid \(record.processID.map(String.init) ?? "?"))"
            } catch {
                message = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func scanPorts() {
        guard let terminal else { return }
        isRunning = true
        message = nil
        _Concurrency.Task {
            let service = DesktopCodingTerminalService.shared
            do {
                let record = try await service.refreshPreviewPorts(updating: terminal)
                model.upsertCodingTerminal(record)
                if record.discoveredPreviewPorts.isEmpty {
                    message = "No localhost listen ports for pid \(record.processID.map(String.init) ?? "?")"
                } else if let port = record.discoveredPreviewPorts.first {
                    message = "Discovered \(record.discoveredPreviewPorts.count) port(s); first http://127.0.0.1:\(port)"
                }
            } catch {
                message = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func runCommand() {
        guard let worktree else { return }
        let command = commandDraft
        isRunning = true
        message = nil
        _Concurrency.Task {
            let service = DesktopCodingTerminalService.shared
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
    @State private var grantMessage: String?

    private var tab: DesktopCodingPreviewTabRecord? {
        model.snapshot.operations.codingPreviewTabs
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
            HStack(spacing: 8) {
                Label("Preview", systemImage: "safari")
                    .font(.caption.weight(.semibold))
                TextField("Local URL", text: $urlDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Open") { openPreview() }
                Button("Refresh") { openPreview() }
                    .disabled(tab == nil)
                Button("Request MCP grant") { requestPreviewMCPGrant() }
                    .disabled(worktree == nil)
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
            if let grantMessage {
                Text(grantMessage)
                    .font(.caption2)
                    .foregroundStyle(Nord.auroraYellow)
                    .padding(8)
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

    private func requestPreviewMCPGrant() {
        guard let worktree else { return }
        let target = CodingPreviewMCPGrant.exactTarget(
            threadID: thread.id,
            worktreePath: worktree.worktreePath
        )
        _ = model.createApproval(
            threadID: thread.id,
            title: CodingPreviewMCPGrant.approvalTitle,
            exactTarget: target,
            consequence: "Inject only curated \(CodingPreviewMCPGrant.curatedServerName) MCP tools (\(CodingPreviewMCPGrant.curatedToolAllowlist.joined(separator: ", "))) into the next coding implementation Codex turn. No blanket user MCP import.",
            dataLeavingDevice: "Localhost MCP tool calls only",
            reversible: true,
            expiresAtUnixMillis: Int64(Date().addingTimeInterval(CodingPreviewMCPGrant.defaultExpirySeconds).timeIntervalSince1970 * 1_000)
        )
        grantMessage = "Preview MCP grant is ready in Inbox (\(CodingPreviewMCPGrant.actionKind))."
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
