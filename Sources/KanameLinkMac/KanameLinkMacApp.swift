import AppKit
import Darwin
import SwiftUI

@main
struct KanameLinkMacApp: App {
    @NSApplicationDelegateAdaptor(KanameLinkAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Kaname Link", id: "main") {
            LinkClientRootView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1_180, height: 760)
    }
}

@MainActor
private final class KanameLinkAppDelegate: NSObject, NSApplicationDelegate {
    private var syntheticSnapshotWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard snapshotPath != nil else { return }
        guard CommandLine.arguments.contains("--synthetic-preview") else {
            fputs("Kaname Link screenshots require --synthetic-preview.\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
        prepareSyntheticSnapshotWindow()
        captureWhenReady(remainingAttempts: 40)
    }

    private var snapshotPath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"),
              arguments.indices.contains(index + 1) else { return nil }
        let path = arguments[index + 1]
        guard path.hasPrefix("/"), path != "/" else { return nil }
        return path
    }

    private func captureWhenReady(remainingAttempts: Int) {
        guard let window = syntheticSnapshotWindow
            ?? NSApplication.shared.windows.first(where: { $0.contentView != nil }) else {
            guard remainingAttempts > 0 else {
                fputs("Kaname Link could not find its preview window.\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.captureWhenReady(remainingAttempts: remainingAttempts - 1)
            }
            return
        }
        window.setContentSize(NSSize(width: 1_180, height: 760))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak window] in
            guard let self, let window, let outputPath = snapshotPath else {
                fputs("Kaname Link could not prepare its preview screenshot.\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }

            // NavigationSplitView uses compositor-backed materials. Capturing the
            // hosting view directly omits those layers, so use the system window
            // compositor for the explicitly synthetic preview instead.
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), outputPath]
            capture.standardOutput = FileHandle.nullDevice
            capture.standardError = FileHandle.nullDevice
            do {
                try capture.run()
                capture.waitUntilExit()
            } catch {
                fputs("Kaname Link could not write its preview screenshot.\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
            guard capture.terminationReason == .exit, capture.terminationStatus == 0 else {
                fputs("Kaname Link could not write its preview screenshot.\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
            Darwin.exit(EXIT_SUCCESS)
        }
    }

    private func prepareSyntheticSnapshotWindow() {
        let controller = NSHostingController(
            rootView: LinkClientRootView().preferredColorScheme(.dark)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kaname Link"
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_180, height: 760))
        window.makeKeyAndOrderFront(nil)
        syntheticSnapshotWindow = window
    }
}

private struct LinkClientRootView: View {
    @State private var model = LinkClientViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            discussionList
        } detail: {
            discussionDetail
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color(red: 0.10, green: 0.12, blue: 0.16))
        .task { await model.load() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isSyntheticPreview {
                Text("Synthetic preview · no real collaborator data or connection")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.22))
                    .accessibilityLabel("Synthetic preview. No real collaborator data or connection.")
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Kaname Link", systemImage: "link.circle.fill")
                    .font(.title2.bold())
                Text("External collaboration")
                    .foregroundStyle(.secondary)
            }
            connectionCard
            Text("LINK SPACES")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            List(selection: $model.selectedSpaceID) {
                ForEach(model.snapshot.spaces) { space in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(space.name).fontWeight(.semibold)
                        Label(
                            space.verified ? "Verified host" : "Verification needed",
                            systemImage: space.verified ? "checkmark.shield.fill" : "exclamationmark.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(space.verified ? Color.green : Color.orange)
                    }
                    .padding(.vertical, 4)
                    .tag(space.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            Spacer()
            Text("This app cannot control Kaname, tools, models, files, or the host computer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
        .background(Color(red: 0.12, green: 0.14, blue: 0.18))
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
    }

    private var connectionCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(connectionColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.snapshot.connection.label).font(.subheadline.weight(.semibold))
                if let space = model.selectedSpace {
                    Text(space.hostName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isWorking { ProgressView().controlSize(.small) }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var discussionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.selectedSpace?.name ?? "Discussions")
                .font(.title2.bold())
                .padding(20)
            Divider()
            List(selection: $model.selectedDiscussionID) {
                ForEach(model.selectedSpace?.discussions ?? []) { discussion in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(discussion.title).fontWeight(.semibold)
                        HStack {
                            Text(discussion.status)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(discussion.status == "Waiting for you" ? Color.orange : Color.green)
                            Spacer()
                            Text(discussion.actionLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    .tag(discussion.id)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 290, ideal: 330, max: 380)
    }

    @ViewBuilder
    private var discussionDetail: some View {
        if model.snapshot.connection == .enrollmentRequired && !model.isSyntheticPreview {
            enrollmentView
        } else if let discussion = model.selectedDiscussion {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(discussion.title).font(.title2.bold())
                        Label(discussion.status, systemImage: "clock.badge.checkmark")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Request change") {}
                        .disabled(model.isSyntheticPreview)
                    Button("Accept") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSyntheticPreview)
                }
                .padding(20)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(discussion.messages) { message in
                            messageBubble(message)
                        }
                    }
                    .padding(24)
                }
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                composer
            }
        } else {
            ContentUnavailableView(
                "No discussion selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Select a Link discussion to see deliberately shared messages.")
            )
        }
    }

    private var enrollmentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Connect to a Kaname host", systemImage: "person.badge.key.fill")
                    .font(.title2.bold())
                Text("Paste the complete invitation created by the host. It is single-use, expires, and grants access only to the named Link space.")
                    .foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Treat the invitation like a password", systemImage: "exclamationmark.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("Do not place it in screenshots, notes, logs, tickets, or chat. Confirm the host and space through a separate channel before requesting approval.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                TextField("Your display name", text: $model.enrollmentDisplayName)
                    .textFieldStyle(.roundedBorder)
                Text("Invitation JSON")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.invitationJSON)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .padding(8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Kaname Link invitation")
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button {
                        Task { await model.enroll() }
                    } label: {
                        if model.isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Request enrollment", systemImage: "lock.shield")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.isWorking
                            || model.invitationJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || model.enrollmentDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private func messageBubble(_ message: LinkClientMessage) -> some View {
        HStack {
            if message.author == .collaborator { Spacer(minLength: 90) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(message.authorName).font(.caption.weight(.bold))
                    Spacer()
                    Text(message.author == .host ? "Shared by host" : "You")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Label(message.receipt, systemImage: receiptSymbol(message.receipt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: 520, alignment: .leading)
            .background(
                message.author == .collaborator
                    ? Color.accentColor.opacity(0.24)
                    : Color.white.opacity(0.075),
                in: RoundedRectangle(cornerRadius: 14)
            )
            if message.author == .host { Spacer(minLength: 90) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message the host", text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .disabled(model.isSyntheticPreview || model.snapshot.connection != .hostOnline)
            Button {
                Task { await model.sendDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || model.isSyntheticPreview
                || model.isWorking)
            .accessibilityLabel("Send message")
        }
        .padding(18)
        .background(.bar)
    }

    private var connectionColor: Color {
        switch model.snapshot.connection {
        case .hostOnline: .green
        case .connecting: .yellow
        case .hostOffline, .enrollmentRequired: .orange
        case .revoked: .red
        }
    }

    private func receiptSymbol(_ receipt: String) -> String {
        receipt == "Published result" ? "checkmark.seal.fill" : "checkmark.circle.fill"
    }
}
