import AppKit
import Darwin
import KanameDesignSystem
import SwiftUI

@main
private enum KanameLinkMacMain {
    @MainActor
    static func main() {
        guard let snapshotPath = snapshotPath else {
            KanameLinkInteractiveApp.main()
            return
        }
        guard CommandLine.arguments.contains("--synthetic-preview") else {
            fputs("Kaname Link screenshots require --synthetic-preview.\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
        do {
            try renderSyntheticSnapshot(at: snapshotPath)
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            fputs("Kaname Link could not write its synthetic preview: \(error)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static var snapshotPath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"),
              arguments.indices.contains(index + 1) else { return nil }
        let path = arguments[index + 1]
        guard path.hasPrefix("/"), path != "/" else { return nil }
        return path
    }

    @MainActor
    private static func renderSyntheticSnapshot(at path: String) throws {
        let content = LinkClientRootView(syntheticPreview: true, snapshotMode: true)
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
            .frame(width: 1_180, height: 760, alignment: .topLeading)
            .clipped()
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private struct KanameLinkSpaceIdentity: View {
    let name: String
    let isVerified: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
            Text(name).fontWeight(.semibold)
            Label(
                isVerified ? "Verified host" : "Verification needed",
                systemImage: isVerified ? "checkmark.shield.fill" : "exclamationmark.shield"
            )
            .font(.caption)
            .foregroundStyle(isVerified ? KanameColor.success : KanameColor.warning)
        }
    }
}

private struct KanameLinkInteractiveApp: App {

    var body: some Scene {
        Window("Kaname Link", id: "main") {
            LinkClientRootView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1_180, height: 760)
    }
}

private struct LinkClientRootView: View {
    @State private var model: LinkClientViewModel
    private let snapshotMode: Bool

    init(syntheticPreview: Bool = false, snapshotMode: Bool = false) {
        _model = State(initialValue: LinkClientViewModel(syntheticPreview: syntheticPreview))
        self.snapshotMode = snapshotMode
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isSyntheticPreview {
                KanameSyntheticDataBanner()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snapshotMode {
                snapshotWorkspace
            } else {
                NavigationSplitView {
                    sidebar
                } content: {
                    discussionList
                } detail: {
                    discussionDetail
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .background(KanameColor.canvas)
        .task { await model.load() }
    }

    private var snapshotWorkspace: some View {
        HStack(spacing: 1) {
            snapshotSidebar
            snapshotDiscussionList
            snapshotDiscussionDetail
        }
        .background(KanameColor.separator)
    }

    private var snapshotSidebar: some View {
        VStack(alignment: .leading, spacing: KanameSpacing.large) {
            VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
                Label("Kaname Link", systemImage: "link.circle.fill")
                    .font(.title2.bold())
                Text("External collaboration")
                    .foregroundStyle(KanameColor.textSecondary)
            }
            connectionCard
            Text("LINK SPACES")
                .font(.caption.weight(.bold))
                .foregroundStyle(KanameColor.textSecondary)
            ForEach(model.snapshot.spaces) { space in
                KanameSurface(padding: KanameSpacing.medium) {
                    KanameLinkSpaceIdentity(name: space.name, isVerified: space.verified)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer()
            KanameAuthorityBoundaryCard(
                title: "Restricted collaborator",
                detail: "This app cannot control Kaname, tools, models, files, or the host computer."
            )
        }
        .padding(KanameSpacing.large)
        .frame(width: 260)
        .background(KanameColor.sidebar)
    }

    private var snapshotDiscussionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.selectedSpace?.name ?? "Discussions")
                .font(.title2.bold())
                .padding(KanameSpacing.large)
            Rectangle().fill(KanameColor.separator).frame(height: 1)
            ForEach(model.selectedSpace?.discussions ?? []) { discussion in
                VStack(alignment: .leading, spacing: KanameSpacing.small) {
                    Text(discussion.title).fontWeight(.semibold)
                    HStack {
                        Text(discussion.status)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(discussion.status == "Waiting for you" ? KanameColor.warning : KanameColor.success)
                        Spacer()
                        Text(discussion.actionLabel)
                            .font(.caption)
                            .foregroundStyle(KanameColor.textSecondary)
                    }
                }
                .padding(KanameSpacing.large)
                .background(discussion.id == model.selectedDiscussionID ? KanameColor.selected : KanameColor.surface)
                Rectangle().fill(KanameColor.separator).frame(height: 1)
            }
            Spacer()
        }
        .frame(width: 320)
        .background(KanameColor.surface)
    }

    @ViewBuilder
    private var snapshotDiscussionDetail: some View {
        if let discussion = model.selectedDiscussion {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
                        Text(discussion.title).font(.title2.bold())
                        Label(discussion.status, systemImage: "clock.badge.checkmark")
                            .font(.subheadline)
                            .foregroundStyle(KanameColor.textSecondary)
                    }
                    Spacer()
                    KanameStatusBadge("Response actions pending", tone: .neutral)
                }
                .padding(KanameSpacing.large)
                Rectangle().fill(KanameColor.separator).frame(height: 1)
                VStack(spacing: KanameSpacing.large) {
                    ForEach(discussion.messages) { message in
                        messageBubble(message)
                    }
                    Spacer()
                }
                .padding(KanameSpacing.xLarge)
                HStack {
                    Text("Synthetic preview · messaging disabled")
                        .foregroundStyle(KanameColor.textTertiary)
                    Spacer()
                    KanameStatusBadge("Send disabled", tone: .neutral)
                }
                .padding(KanameSpacing.large)
                .background(KanameColor.sidebar)
            }
            .background(KanameColor.canvas)
        } else {
            KanameEmptyState(
                "No discussion selected",
                message: "Select a Link discussion to see deliberately shared messages.",
                symbolName: "bubble.left.and.bubble.right"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KanameColor.canvas)
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
                    KanameLinkSpaceIdentity(name: space.name, isVerified: space.verified)
                    .padding(.vertical, 4)
                    .tag(space.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            Spacer()
            KanameAuthorityBoundaryCard(
                title: "Restricted collaborator",
                detail: "This app cannot control Kaname, tools, models, files, or the host computer."
            )
        }
        .padding(16)
        .background(KanameColor.sidebar)
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
        .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: KanameRadius.card, style: .continuous))
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
                                .foregroundStyle(discussion.status == "Waiting for you" ? KanameColor.warning : KanameColor.success)
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
                        .disabled(true)
                        .help("Host response actions are not implemented in this client yet.")
                    Button("Accept") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                        .help("Host response actions are not implemented in this client yet.")
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
                        .foregroundStyle(KanameColor.warning)
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
                            .foregroundStyle(KanameColor.warning)
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
                    .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous))
                    .accessibilityLabel("Kaname Link invitation")
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(KanameColor.warning)
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
            KanameMessageBubble(
                author: message.authorName,
                body: message.body,
                role: message.author == .collaborator ? .collaborator : .host,
                receipt: KanameMessageReceipt(
                    state: message.author == .collaborator ? .gatewayAccepted : .published
                )
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
                .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: KanameRadius.card, style: .continuous))
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
        case .hostOnline: KanameColor.success
        case .connecting: KanameColor.active
        case .hostOffline: KanameColor.warning
        case .enrollmentRequired: KanameColor.external
        case .revoked: KanameColor.danger
        }
    }
}
