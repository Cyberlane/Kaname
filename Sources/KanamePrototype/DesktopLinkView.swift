import Foundation
import KanameDesignSystem
import KanameDesktopUI
import KanameLinkHost
import KanamePrototypeUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
final class DesktopLinkViewModel: ObservableObject {
    @Published private(set) var snapshot: KanameLinkGatewaySnapshot?
    @Published private(set) var activeActionID: String?
    @Published private(set) var failureMessage: String?
    @Published private(set) var invitation: KanameLinkInvitationArtifact?
    @Published private(set) var latestReplyConfirmation: String?

    private var service: (any KanameLinkGatewayService)?
    private var hasStarted = false
#if os(macOS)
    private let runtime: KanameLinkGatewayRuntime?
    private var runtimeMonitor: Task<Void, Never>?
#endif

    init(
        service: any KanameLinkGatewayService,
        initialSnapshot: KanameLinkGatewaySnapshot? = nil
    ) {
        self.service = service
        snapshot = initialSnapshot
#if os(macOS)
        runtime = nil
#endif
    }

#if os(macOS)
    init(runtime: KanameLinkGatewayRuntime) {
        self.runtime = runtime
        service = nil
        snapshot = Self.emptySnapshot(
            lifecycle: .connecting,
            detail: "Preparing the exact bundled Link gateway on loopback."
        )
    }
#endif

    init(unavailableMessage: String) {
        service = nil
#if os(macOS)
        runtime = nil
#endif
        hasStarted = true
        failureMessage = unavailableMessage
        snapshot = Self.emptySnapshot(lifecycle: .offline, detail: unavailableMessage)
    }

    deinit {
#if os(macOS)
        runtimeMonitor?.cancel()
#endif
    }

    var pendingDeviceCount: Int {
        snapshot?.pendingDevices.count ?? 0
    }

    var supportsInvitationCreation: Bool {
        snapshot?.gateway.mode == .bundledAdminCLI && service != nil
    }

    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
#if os(macOS)
        guard let runtime else { return }
        failureMessage = nil
        do {
            _ = try await runtime.start()
            let runner = try await runtime.makeAdminRunner()
            service = KanameLinkProcessGatewayService(runner: runner)
            beginRuntimeMonitoring(runtime)
            await refresh()
        } catch {
            applyRuntimeFailure(error.localizedDescription)
        }
#endif
    }

    func refresh() async {
        guard activeActionID == nil else { return }
        activeActionID = "refresh"
        failureMessage = nil
        defer { activeActionID = nil }
        do {
            let service = try await availableService()
            let next = try await service.fetchSnapshot()
            try KanameLinkSnapshotContract.validate(next)
            snapshot = next
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    func beginInvitationFlow() {
        invitation = nil
        latestReplyConfirmation = nil
        failureMessage = nil
    }

    func createInvitation(
        spaceID: String?,
        spaceName: String,
        expiresInSeconds: UInt64
    ) async {
        guard activeActionID == nil else { return }
        activeActionID = "create-invitation"
        failureMessage = nil
        invitation = nil
        defer { activeActionID = nil }
        do {
            let request = if let spaceID {
                try KanameLinkInvitationRequest(
                    spaceID: spaceID,
                    spaceName: spaceName,
                    expiresInSeconds: expiresInSeconds
                )
            } else {
                try KanameLinkInvitationRequest.newSpace(
                    name: spaceName,
                    expiresInSeconds: expiresInSeconds
                )
            }
            let service = try await availableService()
            invitation = try await service.createInvitation(request: request)
            do {
                let next = try await service.fetchSnapshot()
                try KanameLinkSnapshotContract.validate(next)
                snapshot = next
            } catch {
                failureMessage = "The invitation was created, but the Link snapshot could not be refreshed."
            }
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    func dismissInvitation() { invitation = nil }

    func decide(deviceID: String, decision: KanameLinkDeviceDecision) async {
        guard activeActionID == nil else { return }
        activeActionID = "device:\(deviceID)"
        failureMessage = nil
        defer { activeActionID = nil }
        do {
            let service = try await availableService()
            try await service.decidePendingDevice(id: deviceID, decision: decision)
            let next = try await service.fetchSnapshot()
            try KanameLinkSnapshotContract.validate(next)
            snapshot = next
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    func publishReply(spaceID: String, body: String) async -> Bool {
        guard activeActionID == nil else { return false }
        activeActionID = "reply:\(spaceID)"
        failureMessage = nil
        latestReplyConfirmation = nil
        defer { activeActionID = nil }
        do {
            let service = try await availableService()
            let receipt = try await service.publishReply(spaceID: spaceID, body: body)
            latestReplyConfirmation = "Gateway accepted reply \(receipt.messageID). External delivery is not yet asserted."
            do {
                let next = try await service.fetchSnapshot()
                try KanameLinkSnapshotContract.validate(next)
                snapshot = next
            } catch {
                failureMessage = "The reply was accepted, but the Link snapshot could not be refreshed."
            }
            return true
        } catch {
            failureMessage = error.localizedDescription
            return false
        }
    }

    func isBusy(_ actionID: String) -> Bool {
        activeActionID == actionID
    }

    func stop() async {
#if os(macOS)
        runtimeMonitor?.cancel()
        runtimeMonitor = nil
        if let runtime {
            try? await runtime.stop()
            service = nil
            snapshot = Self.emptySnapshot(
                lifecycle: .offline,
                detail: "The app-lifetime Link gateway has stopped."
            )
        }
#endif
    }

    private func availableService() async throws -> any KanameLinkGatewayService {
#if os(macOS)
        if let runtime {
            let status = await runtime.status()
            guard status.state == .running, status.healthVerified else {
                throw KanameLinkGatewayServiceError.gatewayUnavailable
            }
        }
#endif
        guard let service else { throw KanameLinkGatewayServiceError.gatewayUnavailable }
        return service
    }

#if os(macOS)
    private func beginRuntimeMonitoring(_ runtime: KanameLinkGatewayRuntime) {
        runtimeMonitor?.cancel()
        runtimeMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                let status = await runtime.status()
                if case let .failed(failure) = status.state {
                    service = nil
                    applyRuntimeFailure(failure.localizedDescription)
                    return
                }
            }
        }
    }
#endif

    private func applyRuntimeFailure(_ message: String) {
        failureMessage = message
        snapshot = Self.emptySnapshot(lifecycle: .degraded, detail: message)
    }

    private static func emptySnapshot(
        lifecycle: KanameLinkGatewayLifecycle,
        detail: String
    ) -> KanameLinkGatewaySnapshot {
        KanameLinkGatewaySnapshot(
            gateway: KanameLinkGatewayStatus(
                lifecycle: lifecycle,
                mode: .bundledAdminCLI,
                detail: detail,
                observedAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
            ),
            spaces: [],
            pendingDevices: [],
            externalInbox: [],
            publicationPreviews: [],
            receipts: []
        )
    }
}

struct DesktopLinkView: View {
    @ObservedObject var model: DesktopLinkViewModel
    @State private var invitationDraft: LinkInvitationDraft?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Kaname Link",
                    detail: "Explicitly shared collaboration without trusted-device authority",
                    symbol: "link"
                ) {
                    if model.supportsInvitationCreation {
                        Button {
                            model.beginInvitationFlow()
                            invitationDraft = LinkInvitationDraft(
                                spaceID: nil,
                                spaceName: "",
                                expiresInSeconds: 86_400
                            )
                        } label: {
                            Label("New space invite", systemImage: "person.badge.plus")
                        }
                        .disabled(model.activeActionID != nil)
                    }
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh Link", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.activeActionID != nil)
                }

                BoundaryCallout(
                    title: "Links are not trusted Devices",
                    detail: "Collaborators can see only material explicitly published to their Link space. They cannot enter conversations, run providers or tools, inspect repositories or files, or inherit the Mac’s authority."
                )

                if let failureMessage = model.failureMessage {
                    LinkFailureBanner(message: failureMessage)
                }

                if let snapshot = model.snapshot {
                    LinkGatewayOverview(snapshot: snapshot)

                    LinkSectionHeader(
                        title: "Spaces",
                        detail: "External principals and their explicitly shared scope"
                    )
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300), spacing: 14)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(snapshot.spaces) { space in
                            LinkSpaceCard(
                                space: space,
                                canCreateInvitation: model.supportsInvitationCreation,
                                createInvite: {
                                    model.beginInvitationFlow()
                                    invitationDraft = LinkInvitationDraft(
                                        spaceID: space.id,
                                        spaceName: space.name,
                                        expiresInSeconds: 86_400
                                    )
                                }
                            )
                        }
                    }

                    LinkSectionHeader(
                        title: "Pending device approval",
                        detail: "Verify with the collaborator through a separate channel"
                    )
                    if snapshot.pendingDevices.isEmpty {
                        EmptyPanel(
                            symbol: "checkmark.shield",
                            title: "No external device is waiting",
                            detail: "Trusted Kaname Devices remain managed on their separate surface."
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(snapshot.pendingDevices) { pending in
                                LinkPendingDeviceCard(
                                    pending: pending,
                                    isBusy: model.isBusy("device:\(pending.id)"),
                                    decide: { decision in
                                        Task {
                                            await model.decide(deviceID: pending.id, decision: decision)
                                        }
                                    }
                                )
                            }
                        }
                    }

                    LinkSectionHeader(
                        title: "External inbox",
                        detail: "Plain untrusted data; never instructions for Kaname"
                    )
                    if snapshot.externalInbox.isEmpty {
                        EmptyPanel(
                            symbol: "tray",
                            title: "No external Link messages",
                            detail: "This inbox is intentionally separate from Kaname conversations."
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(snapshot.externalInbox) { message in
                                LinkExternalMessageCard(message: message)
                            }
                        }
                    }

                    LinkReplyComposer(
                        spaces: snapshot.spaces,
                        activeActionID: model.activeActionID,
                        confirmation: model.latestReplyConfirmation,
                        send: { spaceID, body in
                            await model.publishReply(spaceID: spaceID, body: body)
                        }
                    )

                    LinkSectionHeader(
                        title: "Publication preview",
                        detail: "Exactly what approved collaborators can see"
                    )
                    .id("desktop-link-publication-statuses")
                    if snapshot.publicationPreviews.isEmpty {
                        EmptyPanel(
                            symbol: "doc.text.magnifyingglass",
                            title: "No publication preview",
                            detail: "Nothing can be published until a bounded collaborator-visible projection exists."
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(snapshot.publicationPreviews) { preview in
                                LinkPublicationPreviewCard(
                                    preview: preview
                                )
                            }
                        }
                    }

                    LinkSectionHeader(
                        title: "Delivery receipts",
                        detail: "Each stage states only what was directly observed"
                    )
                    if snapshot.receipts.isEmpty {
                        EmptyPanel(
                            symbol: "checkmark.seal",
                            title: "No Link receipts",
                            detail: "Gateway acceptance, relay acceptance, delivery, and opening remain distinct."
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(snapshot.receipts.enumerated()), id: \.element.id) { index, receipt in
                                LinkReceiptRow(
                                    receipt: receipt,
                                    isLast: index == snapshot.receipts.count - 1
                                )
                            }
                        }
                        .padding(.horizontal, 18)
                        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
                    }
                } else {
                    EmptyPanel(
                        symbol: "link.badge.plus",
                        title: "Loading the Link boundary",
                        detail: "No external action occurs while the local gateway snapshot loads."
                    )
                }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task {
                guard CommandLine.arguments.contains("desktop-link-publication-statuses") else { return }
                await _Concurrency.Task<Never, Never>.yield()
                proxy.scrollTo("desktop-link-publication-statuses", anchor: .top)
            }
        }
        .background(Nord.polarNight0)
        .sheet(item: $invitationDraft, onDismiss: model.dismissInvitation) { draft in
            LinkInvitationSheet(model: model, draft: draft)
        }
    }
}

private struct LinkInvitationDraft: Identifiable {
    let id = UUID()
    let spaceID: String?
    let spaceName: String
    let expiresInSeconds: UInt64
}

private struct LinkInvitationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopLinkViewModel
    let spaceID: String?
    @State private var spaceName: String
    @State private var expiresInSeconds: UInt64
    @State private var copyConfirmation: String?
    @State private var copyFailure: String?

    init(model: DesktopLinkViewModel, draft: LinkInvitationDraft) {
        self.model = model
        spaceID = draft.spaceID
        _spaceName = State(initialValue: draft.spaceName)
        _expiresInSeconds = State(initialValue: draft.expiresInSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let invitation = model.invitation {
                invitationResult(invitation)
            } else {
                invitationForm
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Nord.polarNight1)
        .onDisappear { model.dismissInvitation() }
    }

    private var invitationForm: some View {
        Group {
            Label("Secure Link invitation", systemImage: "lock.shield.fill")
                .font(.title2.weight(.bold))
            Text("The invitation is created locally by the bundled gateway. It is never sent automatically and its secret appears only in this explicit copy flow.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                Text("Link space name")
                    .font(.caption.weight(.semibold))
                TextField("Design review", text: $spaceName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(spaceID != nil)
                if spaceID != nil {
                    Text("An existing space keeps its canonical name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Invitation expires")
                    .font(.caption.weight(.semibold))
                Picker("Invitation expires", selection: $expiresInSeconds) {
                    Text("1 hour").tag(UInt64(3_600))
                    Text("24 hours").tag(UInt64(86_400))
                    Text("7 days").tag(UInt64(604_800))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            LinkFact(
                label: "Gateway",
                value: KanameLinkProcessGatewayService.gatewayURL,
                monospaced: true
            )

            if let failure = model.failureMessage {
                LinkFailureBanner(message: failure)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button {
                    Task {
                        await model.createInvitation(
                            spaceID: spaceID,
                            spaceName: spaceName,
                            expiresInSeconds: expiresInSeconds
                        )
                    }
                } label: {
                    Label("Create invitation", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.activeActionID != nil
                        || spaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    @ViewBuilder
    private func invitationResult(_ invitation: KanameLinkInvitationArtifact) -> some View {
        Label("Invitation ready", systemImage: "checkmark.shield.fill")
            .font(.title2.weight(.bold))
            .foregroundStyle(Nord.auroraGreen)
        Text("The secret remains concealed on screen. Copy it only into the intended Kaname Link client, then close this sheet.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 10) {
            LinkFact(label: "Space", value: invitation.spaceName)
            LinkFact(label: "Invitation ID", value: invitation.inviteID, monospaced: true)
            LinkFact(label: "Expires", unixMillis: invitation.expiresAtUnixMillis)
            LinkFact(label: "Secret", value: "Concealed", monospaced: true)
        }
        .padding(14)
        .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 12))

        if let copyConfirmation {
            Label(copyConfirmation, systemImage: "clipboard.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Nord.auroraGreen)
        }
        if let copyFailure {
            Text(copyFailure)
                .font(.caption)
                .foregroundStyle(Nord.auroraRed)
        }

        HStack {
            Button("Close", role: .cancel) { dismiss() }
            Spacer()
            Button {
                copyToConcealedPasteboard(
                    invitation.secretForExplicitCopy(),
                    confirmation: "Secret copied; clipboard clears in two minutes."
                )
            } label: {
                Label("Copy secret only", systemImage: "key")
            }
            Button {
                do {
                    copyToConcealedPasteboard(
                        try invitation.invitationDocumentForExplicitCopy(),
                        confirmation: "Invitation copied; clipboard clears in two minutes."
                    )
                } catch {
                    copyFailure = "The bounded invitation document could not be encoded."
                }
            } label: {
                Label("Copy complete invitation", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @MainActor
    private func copyToConcealedPasteboard(_ value: String, confirmation: String) {
#if os(macOS)
        let pasteboard = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed, transient], owner: nil)
        guard pasteboard.setString(value, forType: .string) else {
            copyFailure = "The invitation could not be placed on the clipboard."
            return
        }
        pasteboard.setData(Data(), forType: concealed)
        pasteboard.setData(Data(), forType: transient)
        let ownedChangeCount = pasteboard.changeCount
        copyFailure = nil
        copyConfirmation = confirmation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            guard pasteboard.changeCount == ownedChangeCount else { return }
            pasteboard.clearContents()
        }
#else
        copyFailure = "Secure clipboard copy is unavailable on this platform."
#endif
    }
}

private struct LinkReplyComposer: View {
    let spaces: [KanameLinkSpaceSummary]
    let activeActionID: String?
    let confirmation: String?
    let send: (String, String) async -> Bool
    @State private var selectedSpaceID = ""
    @State private var replyBody = ""

    private var normalizedBody: String {
        replyBody.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var bodyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Reply with shared text", systemImage: "paperplane")
                    .font(.headline)
                Spacer()
                KanameStatusBadge(
                    KanameDesktopLinkStatusPresentation.linkOnly,
                    density: .compact
                )
            }
            Text("Only the text typed here is published. Kaname conversations, providers, tools, repositories, and files are never attached.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Link space", selection: $selectedSpaceID) {
                ForEach(spaces) { space in
                    Text(space.name).tag(space.id)
                }
            }
            .disabled(spaces.isEmpty)

            TextEditor(text: $replyBody)
                .font(.body)
                .frame(minHeight: 84)
                .padding(8)
                .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Nord.polarNight3, lineWidth: 1)
                }

            HStack {
                if let confirmation {
                    Text(confirmation)
                        .font(.caption)
                        .foregroundStyle(Nord.auroraGreen)
                }
                Spacer()
                Text("\(normalizedBody.utf8.count) / \(KanameLinkSnapshotContract.maximumReplyBodyBytes) bytes")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    let spaceID = selectedSpaceID
                    let reply = normalizedBody
                    Task {
                        if await send(spaceID, reply) { replyBody = "" }
                    }
                } label: {
                    Label("Publish reply", systemImage: "paperplane.fill")
                }
                .disabled(
                    selectedSpaceID.isEmpty
                        || normalizedBody.isEmpty
                        || normalizedBody.utf8.count > KanameLinkSnapshotContract.maximumReplyBodyBytes
                        || activeActionID != nil
                )
            }
        }
        .panelStyle()
        .onAppear {
            if selectedSpaceID.isEmpty { selectedSpaceID = spaces.first?.id ?? "" }
        }
        .onChange(of: spaces.map(\.id)) { _, identifiers in
            if !identifiers.contains(selectedSpaceID) {
                selectedSpaceID = identifiers.first ?? ""
            }
        }
    }

    var body: some View { bodyView }
}

private struct LinkGatewayOverview: View {
    let snapshot: KanameLinkGatewaySnapshot

    var body: some View {
        let status = KanameDesktopLinkStatusPresentation.gateway(snapshot.gateway.lifecycle)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: status.symbolName)
                    .font(.title2)
                    .foregroundStyle(status.tone.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Link gateway")
                        .font(.headline)
                    Text(snapshot.gateway.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                KanameStatusBadge(
                    status,
                    density: .compact
                )
            }

            Divider()

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                LinkMetric(label: "Spaces", value: "\(snapshot.spaces.count)")
                LinkMetric(label: "Pending devices", value: "\(snapshot.pendingDevices.count)")
                LinkMetric(label: "External inbox", value: "\(snapshot.externalInboxCount)")
                LinkMetric(
                    label: "Mode",
                    value: snapshot.gateway.mode == .syntheticFixture ? "Synthetic" : "Bundled CLI"
                )
            }
            if let fingerprint = snapshot.gateway.hostKeyFingerprint {
                LinkFact(label: "Host key fingerprint", value: fingerprint, monospaced: true)
            }
        }
        .panelStyle()
    }
}

private struct LinkMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LinkSpaceCard: View {
    let space: KanameLinkSpaceSummary
    let canCreateInvitation: Bool
    let createInvite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(space.name, systemImage: "person.2.fill")
                    .font(.headline)
                Spacer()
                if space.externalInboxCount > 0 {
                    KanameStatusBadge(
                        KanameDesktopLinkStatusPresentation.externalMessages(space.externalInboxCount),
                        density: .compact
                    )
                }
            }
            LinkFact(label: "Device records", value: "\(space.deviceCount)")
            LinkFact(label: "Messages", value: "\(space.messageCount)")
            LinkFact(label: "Pending devices", value: "\(space.pendingDeviceCount)")
            if let lastActivity = space.lastActivityUnixMillis {
                LinkFact(label: "Last external activity", unixMillis: lastActivity)
            }
            if canCreateInvitation {
                Divider()
                Button(action: createInvite) {
                    Label("Invite another collaborator", systemImage: "person.badge.plus")
                }
                .help("Creates a one-time Link invitation; it never sends automatically")
            }
        }
        .panelStyle()
    }
}

private struct LinkPendingDeviceCard: View {
    let pending: KanameLinkPendingDevice
    let isBusy: Bool
    let decide: (KanameLinkDeviceDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pending.collaboratorDisplayName)
                        .font(.headline)
                    Text("\(pending.deviceLabel) · \(pending.spaceName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KanameStatusBadge(
                    KanameDesktopLinkStatusPresentation.externalDevice,
                    density: .compact
                )
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Verification words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let verificationCode = pending.verificationCode {
                        Text(verbatim: verificationCode)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                    } else {
                        Text("Unavailable — approval is disabled")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Nord.auroraRed)
                    }
                }
                Spacer()
                LinkRelativeTime(unixMillis: pending.requestedAtUnixMillis)
            }
            .padding(12)
            .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 10))

            Text("Confirm these words with the named collaborator through a separate trusted channel before approving.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Approve device", systemImage: "checkmark.shield") {
                    decide(.approve)
                }
                .disabled(isBusy || pending.verificationCode == nil)
                Button("Deny", systemImage: "xmark.shield", role: .destructive) {
                    decide(.deny)
                }
                .disabled(isBusy || pending.verificationCode == nil)
            }
        }
        .panelStyle()
    }
}

private struct LinkExternalMessageCard: View {
    let message: KanameLinkExternalMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.senderDisplayName)
                        .font(.headline)
                    Text(message.spaceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KanameStatusBadge(
                    KanameDesktopLinkStatusPresentation.externalUntrusted,
                    density: .compact
                )
            }
            Text(verbatim: message.body)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Untrusted external message: \(message.body)")
            Divider()
            HStack {
                Label("Data only — never executed", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Nord.auroraYellow)
                Spacer()
                LinkRelativeTime(unixMillis: message.receivedAtUnixMillis)
            }
        }
        .panelStyle()
    }
}

private struct LinkPublicationPreviewCard: View {
    let preview: KanameLinkPublicationPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.title)
                        .font(.title3.weight(.bold))
                    Text(preview.spaceName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KanameStatusBadge(
                    KanameDesktopLinkStatusPresentation.publication(preview.state),
                    density: .compact
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Collaborator-visible material")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Nord.frost1)
                Text(verbatim: preview.summary)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 12))

            LinkFact(label: "Audience", value: preview.audienceDescription)
            LinkFact(label: "Revision", value: "\(preview.revision)")
            LinkFact(label: "Content digest", value: preview.contentDigest, monospaced: true)
            if let expires = preview.expiresAtUnixMillis {
                LinkFact(label: "Expires", unixMillis: expires)
            }

            Text("This is a read-only projection preview. Gateway acceptance, relay delivery, and collaborator review remain distinct states.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .panelStyle()
    }
}

private struct LinkReceiptRow: View {
    let receipt: KanameLinkReceipt
    let isLast: Bool

    var body: some View {
        let status = KanameDesktopLinkStatusPresentation.receipt(receipt.stage)
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 0) {
                Image(systemName: status.symbolName)
                    .foregroundStyle(status.tone.color)
                    .accessibilityHidden(true)
                if !isLast {
                    Rectangle()
                        .fill(Nord.polarNight3)
                        .frame(width: 2, height: 62)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(receipt.summary)
                        .font(.headline)
                    Spacer()
                    KanameStatusBadge(status, density: .compact)
                }
                Text(receipt.spaceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(receipt.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LinkRelativeTime(unixMillis: receipt.recordedAtUnixMillis)
            }
            .padding(.bottom, isLast ? 16 : 4)
        }
        .padding(.top, 16)
    }
}

private struct LinkSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct LinkFact: View {
    let label: String
    let value: String?
    let unixMillis: Int64?
    let monospaced: Bool

    init(label: String, value: String, monospaced: Bool = false) {
        self.label = label
        self.value = value
        unixMillis = nil
        self.monospaced = monospaced
    }

    init(label: String, unixMillis: Int64) {
        self.label = label
        value = nil
        self.unixMillis = unixMillis
        monospaced = false
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(verbatim: value)
                    .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                    .multilineTextAlignment(.trailing)
            } else if let unixMillis {
                LinkRelativeTime(unixMillis: unixMillis)
            }
        }
    }
}

private struct LinkRelativeTime: View {
    let unixMillis: Int64

    var body: some View {
        Text(Date(timeIntervalSince1970: TimeInterval(unixMillis) / 1_000), style: .relative)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct LinkFailureBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Nord.auroraRed)
            VStack(alignment: .leading, spacing: 4) {
                Text("Link gateway unavailable")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Nord.auroraRed.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
    }
}
