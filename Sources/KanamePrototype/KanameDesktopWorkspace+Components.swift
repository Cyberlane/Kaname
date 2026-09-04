import KanameDesktop
import KanameDesktopUI
import KanameDesignSystem
import KanameWorkflowHost
import KanameConnectivity
import KanameDomain
import KanamePrototypeUI
import KanameLocalCore
import KanameLinkHost
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct DesktopSheetActionBar: View {
    let primaryTitle: String
    let isPrimaryEnabled: Bool
    let dismiss: () -> Void
    let performPrimary: () -> Void

    var body: some View {
        HStack {
            Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
            Button(primaryTitle, action: performPrimary)
                .buttonStyle(.borderedProminent)
                .disabled(!isPrimaryEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct AccountStrip: View {
    let accounts: [DesktopAccountRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accounts & scope")
                .font(.headline)
            ForEach(accounts) { account in
                HStack(spacing: 12) {
                    Image(systemName: account.service.symbol)
                        .foregroundStyle(account.status == .ready ? KanameColor.success : .secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(account.identity)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(account.scope)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    KanameStatusBadge(
                        KanameDesktopStatusPresentation.record(account.status),
                        density: .compact
                    )
                }
            }
        }
        .panelStyle()
    }
}

struct ApprovalQueueStrip: View {
    @ObservedObject var model: DesktopAppModel

    private var pending: [DesktopApprovalRecord] {
        model.snapshot.operations.approvals.filter { $0.state == .awaitingApproval }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Approval proposals", systemImage: "checkmark.shield.fill")
                    .font(.headline)
                Spacer()
                Text("\(pending.count) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(pending) { approval in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(approval.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        KanameStatusBadge(
                            KanameDesktopStatusPresentation.record(.needsReview),
                            density: .compact
                        )
                    }
                    Text(approval.exactTarget)
                        .font(.system(.caption, design: .monospaced))
                    Text(approval.consequence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Label(approval.reversible ? "Reversible" : "Not reversible", systemImage: approval.reversible ? "arrow.uturn.backward.circle" : "exclamationmark.triangle")
                        if !approval.dataLeavingDevice.isEmpty {
                            Label(approval.dataLeavingDevice, systemImage: "arrow.up.right.square")
                        }
                        Spacer()
                        Button("Reject") { model.resolveApproval(id: approval.id, approved: false) }
                        Button("Record approval") { model.resolveApproval(id: approval.id, approved: true) }
                            .buttonStyle(.borderedProminent)
                    }
                    .font(.caption)
                }
                .padding(12)
                .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 10))
            }
            if pending.isEmpty {
                Text("No action is waiting for approval.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Recording a decision here never dispatches the proposed external action by itself.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .panelStyle()
    }
}

struct DesktopAuthorityCard: View {
    let remote: DesktopRemoteStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent {
                Text("Foundation")
                    .kanameSemanticFont(.caption.weight(.bold))
                    .foregroundStyle(KanameColor.warning)
            } label: {
                Label("Local authority", systemImage: "desktopcomputer")
                    .kanameSemanticFont(.headline)
            }
            InspectorStatus(label: "Workspace", value: "Configured · not verified", tint: KanameColor.warning)
            InspectorStatus(label: "Remote", value: remote.relayStatus, tint: KanameColor.warning)
            InspectorStatus(label: "Phone", value: "Not run · deferred", tint: KanameColor.warning)
        }
        .padding(15)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Spacer()
                Text(value)
                    .kanameSemanticFont(.title2.weight(.bold))
            }
            Text(title)
                .kanameSemanticFont(.headline)
            Text(detail)
                .kanameSemanticFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(KanameSpacing.large)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(
            KanameColor.surface,
            in: RoundedRectangle(cornerRadius: KanameRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: KanameRadius.card, style: .continuous)
                .stroke(KanameColor.separator.opacity(0.72), lineWidth: 1)
        }
    }
}

struct SectionHeading: View {
    let title: String
    let detail: String

    var body: some View {
        KanameSectionHeader(title, detail: detail)
    }
}

struct ThreadCard: View {
    let thread: DesktopThread
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    KanameStatusBadge(
                        KanameDesktopStatusPresentation.attention(thread.attention),
                        density: .compact
                    )
                    Spacer()
                    Image(systemName: thread.kind.symbol)
                        .foregroundStyle(.secondary)
                }
                Text(thread.title)
                    .kanameSemanticFont(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(thread.summary)
                    .kanameSemanticFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Divider()
                HStack {
                    Text(thread.provider)
                    Spacer()
                    RelativeTime(unixMillis: thread.updatedAtUnixMillis)
                }
                .kanameSemanticFont(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(thread.title). \(thread.summary). Attention: \(thread.attention.label). Provider: \(thread.provider)")
        .accessibilityHint("Open conversation")
    }
}

struct ThreadRow: View {
    let thread: DesktopThread
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: thread.kind.symbol)
                    .foregroundStyle(thread.attention.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(thread.title)
                            .kanameSemanticFont(.headline)
                            .lineLimit(1)
                        if thread.unread {
                            Circle().fill(KanameColor.accent).frame(width: 7, height: 7)
                        }
                    }
                    Text(thread.summary)
                        .kanameSemanticFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                KanameStatusBadge(
                    KanameDesktopStatusPresentation.attention(thread.attention),
                    density: .compact
                )
                Image(systemName: "chevron.right")
                    .kanameSemanticFont(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(13)
            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(thread.unread ? "Unread. " : "")\(thread.title). \(thread.summary). Attention: \(thread.attention.label)")
        .accessibilityHint("Open conversation")
    }
}

struct ThreadDirectoryLabel: View {
    let thread: DesktopThread
    let runs: [DesktopProviderRunRecord]

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: thread.kind.symbol)
                .foregroundStyle(ThreadDirectoryStatus(thread: thread, runs: runs).tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(thread.title)
                        .font(.headline)
                        .lineLimit(1)
                    if thread.unread { Circle().fill(KanameColor.accent).frame(width: 7, height: 7) }
                }
                Text("\(thread.provider) · \(thread.kind.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ThreadDirectoryStatusView(status: ThreadDirectoryStatus(thread: thread, runs: runs))
            }
        }
        .padding(.vertical, 5)
        .frame(height: 70, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(thread.unread ? "Unread. " : "")\(thread.title). \(thread.provider). \(ThreadDirectoryStatus(thread: thread, runs: runs).label)"
        )
    }
}

private struct ThreadDirectoryStatus {
    let label: String
    let symbol: String
    let tint: Color
    let runningSinceUnixMillis: Int64?

    init(thread: DesktopThread, runs: [DesktopProviderRunRecord]) {
        let runningSince = runs.last(where: { $0.state == .running })?.startedAtUnixMillis
        switch thread.attention {
        case .needsApproval:
            (label, symbol, tint, runningSinceUnixMillis) = ("Approval required", "hand.raised.fill", KanameColor.warning, nil)
        case .needsInput:
            (label, symbol, tint, runningSinceUnixMillis) = ("Waiting for input", "questionmark.bubble.fill", KanameColor.blocked, nil)
        case .failed:
            (label, symbol, tint, runningSinceUnixMillis) = ("Failed", "exclamationmark.circle.fill", KanameColor.danger, nil)
        case .running:
            (label, symbol, tint, runningSinceUnixMillis) = ("Running", "circle.dashed", KanameColor.accent, runningSince)
        case .queued:
            (label, symbol, tint, runningSinceUnixMillis) = ("Queued", "clock", .secondary, nil)
        case .needsResponse:
            (label, symbol, tint, runningSinceUnixMillis) = (
                thread.unread ? "Response ready" : "Ready",
                thread.unread ? "checkmark.circle.fill" : "circle",
                thread.unread ? KanameColor.success : .secondary,
                nil
            )
        case .completed:
            (label, symbol, tint, runningSinceUnixMillis) = ("Complete", "checkmark", .secondary, nil)
        case .archived:
            (label, symbol, tint, runningSinceUnixMillis) = ("Archived", "archivebox", .secondary, nil)
        }
    }
}

private struct ThreadDirectoryStatusView: View {
    let status: ThreadDirectoryStatus

    var body: some View {
        Group {
            if let started = status.runningSinceUnixMillis {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    statusLabel(duration: max(0, Int64(context.date.timeIntervalSince1970 * 1_000) - started))
                }
            } else {
                statusLabel(duration: nil)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(status.tint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLabel(duration: Int64?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
            Text(status.label)
            if let duration {
                Text(Self.durationLabel(milliseconds: duration))
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
    }

    private static func durationLabel(milliseconds: Int64) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    }
}

struct InboxThreadLabel: View {
    let thread: DesktopThread

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(thread.attention.tint).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .font(.headline)
                Text(thread.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            KanameStatusBadge(
                KanameDesktopStatusPresentation.attention(thread.attention),
                density: .compact
            )
            RelativeTime(unixMillis: thread.updatedAtUnixMillis)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(thread.unread ? "Unread. " : "")\(thread.title). \(thread.summary). Attention: \(thread.attention.label)")
    }
}

struct QuickActionCard: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .kanameSemanticFont(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).kanameSemanticFont(.headline)
                    Text(detail)
                        .kanameSemanticFont(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(15)
            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }
}

struct ProjectCard: View {
    let project: DesktopProject
    let threads: [DesktopThread]
    let openProject: () -> Void
    let startConversation: () -> Void
    let openThread: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button(action: openProject) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .foregroundStyle(KanameColor.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(.title3.weight(.bold))
                            Text("\(threads.count) active thread\(threads.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open project overview")
                Spacer()
                Button(action: startConversation) {
                    Image(systemName: "square.and.pencil")
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(KanameColor.raised, in: Circle())
                }
                .buttonStyle(.plain)
                .help("New conversation in \(project.name)")
                .accessibilityLabel("New conversation in \(project.name)")
            }
            Button(action: openProject) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.summary.isEmpty ? "No purpose recorded yet." : project.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let path = project.path {
                        Label(path, systemImage: "externaldrive")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 12) {
                        Label("\(project.context.knowledgeSourceIDs.count)", systemImage: "books.vertical")
                        Label("\(project.context.skillIDs.count)", systemImage: "hammer")
                        Label(project.context.defaultProvider, systemImage: "cpu")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(project.name) project overview")
            Divider()
            if threads.isEmpty {
                Text("No active work")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(threads.prefix(3)) { thread in
                    Button { openThread(thread.id) } label: {
                        HStack {
                            Circle().fill(thread.attention.tint).frame(width: 7, height: 7)
                            Text(thread.title).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .accessibilityLabel("Open \(thread.title). Attention: \(thread.attention.label)")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 17))
    }
}

struct DeviceEndpointCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let status: String
    let tint: Color
    let facts: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(tint)
                    .frame(width: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.bold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Divider()
            ForEach(facts, id: \.0) { fact in
                LabeledContent(fact.0, value: fact.1)
                    .font(.subheadline)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 205, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 17))
    }
}

struct RemoteStatusCard: View {
    let title: String
    let status: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            Text(title).font(.headline)
            Text(status)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct RemoteTimelineRow: View {
    let event: DesktopRemoteEvent
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 0) {
                Image(systemName: event.state.symbol)
                    .foregroundStyle(event.state.tint)
                    .background(KanameColor.surface)
                if !isLast {
                    Rectangle()
                        .fill(KanameColor.separator)
                        .frame(width: 1, height: 45)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.title).font(.headline)
                    Spacer()
                    Text(event.state.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(event.state.tint)
                }
                Text(event.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 16 : 4)
        }
        .padding(.top, 16)
    }
}

struct BoundaryCallout: View {
    let title: String
    let detail: String

    var body: some View {
        KanameCallout(title, message: detail, tone: .attention)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DesktopDecisionFooter<Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    init(title: String, detail: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                decisionText
                Spacer(minLength: 12)
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                decisionText
                actions
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(KanameColor.surface)
    }

    private var decisionText: some View {
        (
            Text(title).font(.subheadline.weight(.semibold))
                + Text("\n")
                + Text(detail).font(.caption).foregroundColor(KanameColor.textPrimary.opacity(0.72))
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SurfaceHeader<Actions: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder let actions: Actions

    init(title: String, detail: String, symbol: String, @ViewBuilder actions: () -> Actions) {
        (self.title, self.detail, self.symbol, self.actions) = (title, detail, symbol, actions())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(KanameColor.accentStrong)
                .frame(width: 42, height: 42)
                .background(
                    KanameColor.raised,
                    in: RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(KanameTypography.display)
                Text(detail)
                    .font(KanameTypography.supporting)
                    .foregroundStyle(KanameColor.textSecondary)
                    .lineLimit(2)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            actions.fixedSize(horizontal: true, vertical: false)
        }
        .padding(22)
    }
}

extension SurfaceHeader where Actions == EmptyView {
    init(title: String, detail: String, symbol: String) {
        self.init(title: title, detail: detail, symbol: symbol) { EmptyView() }
    }
}

struct EmptyPanel: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        KanameSurface(padding: 0) {
            KanameEmptyState(title, message: detail, symbolName: symbol)
                .frame(maxWidth: .infinity, minHeight: 180)
        }
    }
}

struct RelativeTime: View {
    let unixMillis: Int64

    var body: some View {
        Text(Date(timeIntervalSince1970: TimeInterval(unixMillis) / 1_000), style: .relative)
    }
}

struct InspectorTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.title3.weight(.bold))
    }
}

struct InspectorFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).textSelection(.enabled)
        }
    }
}

struct InspectorStatus: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .kanameSemanticFont(.caption)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.headline)
            Divider()
            content
        }
        .panelStyle()
    }
}

extension View {
    func panelStyle() -> some View {
        padding(KanameSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                KanameColor.raised.opacity(0.72),
                in: RoundedRectangle(cornerRadius: KanameRadius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: KanameRadius.card, style: .continuous)
                    .stroke(KanameColor.separator.opacity(0.72), lineWidth: 1)
            }
    }

    func desktopAdaptiveSheet(
        idealWidth: Double,
        idealHeight: Double? = nil
    ) -> some View {
        modifier(DesktopAdaptiveSheetModifier(idealWidth: idealWidth, idealHeight: idealHeight))
    }
}

private struct DesktopAdaptiveSheetModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.desktopQALargeText) private var usesQALargeText
    let idealWidth: Double
    let idealHeight: Double?

    @ViewBuilder
    func body(content: Content) -> some View {
        let metrics = DesktopAccessibleSheetMetrics.adaptive(
            idealWidth: idealWidth,
            idealHeight: idealHeight,
            usesAccessibilityTextSize: usesQALargeText || dynamicTypeSize.isAccessibilitySize
        )
        if let minimumHeight = metrics.minimumHeight,
           let idealHeight = metrics.idealHeight,
           let maximumHeight = metrics.maximumHeight {
            content.frame(
                minWidth: CGFloat(metrics.minimumWidth),
                idealWidth: CGFloat(metrics.idealWidth),
                maxWidth: CGFloat(metrics.maximumWidth),
                minHeight: CGFloat(minimumHeight),
                idealHeight: CGFloat(idealHeight),
                maxHeight: CGFloat(maximumHeight)
            )
        } else {
            content.frame(
                minWidth: CGFloat(metrics.minimumWidth),
                idealWidth: CGFloat(metrics.idealWidth),
                maxWidth: CGFloat(metrics.maximumWidth)
            )
        }
    }
}
