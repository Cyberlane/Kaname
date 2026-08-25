import AppKit
import Darwin
import KanameDesignSystem
import SwiftUI

@main
private enum KanameLinkMacMain {
    @MainActor
    static func main() {
        if let contractPath = statusContractPath {
            do {
                try LinkStatusContractVerifier.verify(at: contractPath)
                print("Kaname Link macOS status contract passed.")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                fputs("Kaname Link status contract failed: \(error)\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
        }
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

    private static var statusContractPath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--verify-status-contract"),
              arguments.indices.contains(index + 1) else { return nil }
        let path = arguments[index + 1]
        guard path.hasPrefix("/"), path != "/" else { return nil }
        return path
    }

    @MainActor
    private static func renderSyntheticSnapshot(at path: String) throws {
        let configuration = LinkDesignCaptureConfiguration.current
        let content = LinkClientRootView(syntheticPreview: true, snapshotMode: true)
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, configuration.locale)
            .environment(\.kanameAccessibilityPreferences, configuration.accessibilityPreferences)
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

private struct LinkDesignCaptureConfiguration {
    let locale: Locale
    let accessibilityPreferences: KanameAccessibilityPreferences

    static var current: Self {
        let environment = ProcessInfo.processInfo.environment
        let identifier = environment["KANAME_DESIGN_SCENARIO_ID"] ?? "link-macos-synthetic"
        guard ["link-macos-synthetic", "link-macos-synthetic-large-text"].contains(identifier) else {
            preconditionFailure("Unsupported Kaname Link design screenshot scenario: \(identifier)")
        }
        guard (environment["KANAME_DESIGN_APPEARANCE"] ?? "dark") == "dark" else {
            preconditionFailure("Kaname Link design screenshots currently support dark appearance only")
        }

        let textScaleValue = environment["KANAME_DESIGN_TEXT_SCALE"] ?? "standard"
        guard let syntheticTextScale = KanameSyntheticTextScale(rawValue: textScaleValue) else {
            preconditionFailure("Unsupported Kaname Link design screenshot text scale: \(textScaleValue)")
        }

        let differentiate = parseBoolean(
            environment["KANAME_DESIGN_DIFFERENTIATE_WITHOUT_COLOR"] ?? "false",
            name: "KANAME_DESIGN_DIFFERENTIATE_WITHOUT_COLOR"
        )
        let reduceMotion = parseBoolean(
            environment["KANAME_DESIGN_REDUCE_MOTION"] ?? "false",
            name: "KANAME_DESIGN_REDUCE_MOTION"
        )
        return Self(
            locale: Locale(identifier: environment["KANAME_DESIGN_LOCALE"] ?? "en_US"),
            accessibilityPreferences: KanameAccessibilityPreferences(
                differentiateWithoutColor: differentiate,
                reduceMotion: reduceMotion,
                increasedContrast: false,
                syntheticTextScale: syntheticTextScale
            )
        )
    }

    private static func parseBoolean(_ value: String, name: String) -> Bool {
        switch value {
        case "true": true
        case "false": false
        default: preconditionFailure("\(name) must be true or false")
        }
    }
}

private struct KanameLinkSpaceIdentity: View {
    let name: String
    let isVerified: Bool

    var body: some View {
        let verification = isVerified
            ? LinkHostVerificationState.verified
            : LinkHostVerificationState.approvalPending
        VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
            Text(name).kanameSemanticFont(.body.weight(.semibold))
            KanameStatusBadge(verification.presentation, density: .compact)
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
    @Environment(\.kanameAccessibilityPreferences) private var accessibilityPreferences
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
        .kanameSemanticFont(.body)
        .task { await model.load() }
        .onChange(of: model.snapshot.connection) { previous, current in
            guard previous != current else { return }
            KanameAccessibilityAnnouncement.post(current.presentation.accessibilityLabel)
        }
    }

    private var snapshotWorkspace: some View {
        HStack(spacing: 1) {
            snapshotSidebar
            snapshotDiscussionList
            snapshotDiscussionDetail
        }
        .background(KanameColor.separator)
    }

    private var usesSyntheticLargeText: Bool {
        accessibilityPreferences.syntheticTextScale == .accessibility3
    }

    private var snapshotSidebar: some View {
        VStack(alignment: .leading, spacing: KanameSpacing.large) {
            VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
                Label("Kaname Link", systemImage: "link.circle.fill")
                    .kanameSemanticFont(.title2.bold())
                Text("External collaboration")
                    .foregroundStyle(KanameColor.textSecondary)
            }
            connectionCard
            Text("LINK SPACES")
                .kanameSemanticFont(.caption.weight(.bold))
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trust boundary: Restricted collaborator")
        }
        .padding(KanameSpacing.large)
        .frame(width: usesSyntheticLargeText ? 300 : 260)
        .background(KanameColor.sidebar)
    }

    private var snapshotDiscussionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.selectedSpace?.name ?? "Discussions")
                .kanameSemanticFont(.title2.bold())
                .padding(KanameSpacing.large)
            Rectangle().fill(KanameColor.separator).frame(height: 1)
            ForEach(model.selectedSpace?.discussions ?? []) { discussion in
                VStack(alignment: .leading, spacing: KanameSpacing.small) {
                    Text(discussion.title).kanameSemanticFont(.body.weight(.semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            KanameStatusBadge(discussion.status.presentation, density: .compact)
                            Spacer()
                            Text(discussion.actionLabel)
                                .kanameSemanticFont(.caption)
                                .foregroundStyle(KanameColor.textSecondary)
                        }
                        VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
                            KanameStatusBadge(discussion.status.presentation, density: .compact)
                            Text(discussion.actionLabel)
                                .kanameSemanticFont(.caption)
                                .foregroundStyle(KanameColor.textSecondary)
                        }
                    }
                }
                .padding(KanameSpacing.large)
                .background(discussion.id == model.selectedDiscussionID ? KanameColor.selected : KanameColor.surface)
                Rectangle().fill(KanameColor.separator).frame(height: 1)
            }
            Spacer()
        }
        .frame(width: usesSyntheticLargeText ? 360 : 320)
        .background(KanameColor.surface)
    }

    @ViewBuilder
    private var snapshotDiscussionDetail: some View {
        if let discussion = model.selectedDiscussion {
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) {
                        snapshotDiscussionIdentity(discussion)
                        Spacer()
                        responseActionsPendingBadge
                    }
                    VStack(alignment: .leading, spacing: KanameSpacing.small) {
                        snapshotDiscussionIdentity(discussion)
                        responseActionsPendingBadge
                    }
                }
                .padding(KanameSpacing.large)
                Rectangle().fill(KanameColor.separator).frame(height: 1)
                VStack(spacing: KanameSpacing.large) {
                    ForEach(discussion.messages) { message in
                        messageBubble(message)
                    }
                    Spacer(minLength: 0)
                }
                .padding(KanameSpacing.xLarge)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Synthetic preview · messaging disabled")
                            .foregroundStyle(KanameColor.textTertiary)
                        Spacer()
                        KanameStatusBadge("Send disabled", tone: .neutral)
                    }
                    VStack(alignment: .leading, spacing: KanameSpacing.small) {
                        Text("Synthetic preview · messaging disabled")
                            .foregroundStyle(KanameColor.textTertiary)
                        KanameStatusBadge("Send disabled", tone: .neutral)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func snapshotDiscussionIdentity(_ discussion: LinkClientDiscussion) -> some View {
        VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
            Text(discussion.title).kanameSemanticFont(.title2.bold())
            KanameStatusBadge(discussion.status.presentation, density: .compact)
        }
    }

    private var responseActionsPendingBadge: some View {
        KanameStatusBadge(
            KanameStatusPresentation(
                label: "Response actions pending",
                tone: .neutral,
                symbolName: KanameStatusTone.neutral.symbolName,
                accessibilityLabel: "Action status: Response actions pending"
            ),
            density: .compact
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Kaname Link", systemImage: "link.circle.fill")
                    .kanameSemanticFont(.title2.bold())
                Text("External collaboration")
                    .foregroundStyle(.secondary)
            }
            connectionCard
            Text("LINK SPACES")
                .kanameSemanticFont(.caption.weight(.bold))
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trust boundary: Restricted collaborator")
        }
        .padding(16)
        .background(KanameColor.sidebar)
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
    }

    private var connectionCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                KanameStatusBadge(model.snapshot.connection.presentation, density: .compact)
                if let space = model.selectedSpace {
                    Text(space.hostName).kanameSemanticFont(.caption).foregroundStyle(.secondary)
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
                .kanameSemanticFont(.title2.bold())
                .padding(20)
            Divider()
            List(selection: $model.selectedDiscussionID) {
                ForEach(model.selectedSpace?.discussions ?? []) { discussion in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(discussion.title).kanameSemanticFont(.body.weight(.semibold))
                        HStack {
                            KanameStatusBadge(discussion.status.presentation, density: .compact)
                            Spacer()
                            Text(discussion.actionLabel)
                                .kanameSemanticFont(.caption)
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
                        Text(discussion.title).kanameSemanticFont(.title2.bold())
                        KanameStatusBadge(discussion.status.presentation, density: .compact)
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
                        .kanameSemanticFont(.caption)
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
                    .kanameSemanticFont(.title2.bold())
                Text("Paste the complete invitation created by the host. It is single-use, expires, and grants access only to the named Link space.")
                    .foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Treat the invitation like a password", systemImage: "exclamationmark.shield.fill")
                            .kanameSemanticFont(.headline)
                            .foregroundStyle(KanameColor.warning)
                        Text("Do not place it in screenshots, notes, logs, tickets, or chat. Confirm the host and space through a separate channel before requesting approval.")
                            .kanameSemanticFont(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                TextField("Your display name", text: $model.enrollmentDisplayName)
                    .textFieldStyle(.roundedBorder)
                Text("Invitation JSON")
                    .kanameSemanticFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.invitationJSON)
                    .kanameSemanticFont(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .padding(8)
                    .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous))
                    .accessibilityLabel("Kaname Link invitation")
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle.fill")
                        .kanameSemanticFont(.subheadline)
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

    @ViewBuilder
    private func messageBubble(_ message: LinkClientMessage) -> some View {
        HStack {
            if message.author.isLocalPrincipal { Spacer(minLength: 90) }
            if let role = message.author.kanameRole {
                KanameMessageBubble(
                    author: message.authorName,
                    body: message.body,
                    role: role,
                    participantPresentation: message.author.presentation,
                    receipt: KanameMessageReceipt(state: message.receipt.kanameState),
                    receiptPresentation: message.receipt.presentation
                )
            } else {
                KanameSurface(padding: KanameSpacing.medium) {
                    VStack(alignment: .leading, spacing: KanameSpacing.small) {
                        KanameStatusBadge(message.author.presentation, density: .compact)
                        Text(message.authorName).kanameSemanticFont(.caption.weight(.bold))
                        Text(message.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        KanameStatusBadge(message.receipt.presentation, density: .compact)
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            if !message.author.isLocalPrincipal { Spacer(minLength: 90) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message the host", text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(12)
                .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: KanameRadius.card, style: .continuous))
                .disabled(
                    model.isSyntheticPreview
                        || !model.snapshot.connection.capabilities.canQueueMessage
                )
            Button {
                Task { await model.sendDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .kanameSemanticFont(.title2)
            }
            .buttonStyle(.plain)
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || model.isSyntheticPreview
                || model.isWorking
                || !model.snapshot.connection.capabilities.canQueueMessage)
            .accessibilityLabel("Send message")
        }
        .padding(18)
        .background(.bar)
    }

}
