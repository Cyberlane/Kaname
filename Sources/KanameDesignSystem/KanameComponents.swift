import SwiftUI

public struct KanameSurface<Content: View>: View {
    private let content: Content
    private let padding: CGFloat
    private let background: Color

    public init(
        padding: CGFloat = KanameSpacing.large,
        background: Color = KanameColor.surface,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.background = background
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(background, in: RoundedRectangle(cornerRadius: KanameRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: KanameRadius.card, style: .continuous)
                    .stroke(KanameColor.separator.opacity(0.72), lineWidth: 1)
            }
    }
}

public struct KanameStatusPresentation: Equatable, Sendable {
    public let label: String
    public let tone: KanameStatusTone
    public let symbolName: String
    public let accessibilityLabel: String

    public init(
        label: String,
        tone: KanameStatusTone,
        symbolName: String,
        accessibilityLabel: String
    ) {
        self.label = label
        self.tone = tone
        self.symbolName = symbolName
        self.accessibilityLabel = accessibilityLabel
    }
}

public enum KanameBadgeDensity: String, CaseIterable, Codable, Sendable {
    case compact
    case regular
}

/// Resolves native and deterministic preview contrast preferences without
/// consulting global state, so component behavior can be tested directly.
public enum KanameContrastResolution: Equatable, Sendable {
    case standard
    case increased

    public static func resolve(
        nativeColorSchemeContrast: ColorSchemeContrast,
        accessibilityPreferences: KanameAccessibilityPreferences
    ) -> Self {
        nativeColorSchemeContrast == .increased || accessibilityPreferences.increasedContrast
            ? .increased
            : .standard
    }
}

private extension KanameBadgeDensity {
    var font: Font {
        switch self {
        case .compact: .caption2.weight(.semibold)
        case .regular: .caption.weight(.semibold)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: KanameSpacing.xSmall
        case .regular: KanameSpacing.small
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: KanameSpacing.hairline
        case .regular: KanameSpacing.xSmall
        }
    }
}

private extension KanameContrastResolution {
    var fillOpacity: Double {
        switch self {
        case .standard: 0.14
        case .increased: 0.24
        }
    }

    var strokeOpacity: Double {
        switch self {
        case .standard: 0.42
        case .increased: 0.82
        }
    }

    var strokeWidth: CGFloat {
        switch self {
        case .standard: 1
        case .increased: 2
        }
    }
}

public struct KanameStatusBadge: View {
    private let presentation: KanameStatusPresentation
    private let density: KanameBadgeDensity
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.kanameAccessibilityPreferences) private var accessibilityPreferences

    public init(
        _ presentation: KanameStatusPresentation,
        density: KanameBadgeDensity = .regular
    ) {
        self.presentation = presentation
        self.density = density
    }

    public init(_ label: String, tone: KanameStatusTone) {
        self.init(
            KanameStatusPresentation(
                label: label,
                tone: tone,
                symbolName: tone.symbolName,
                accessibilityLabel: label
            )
        )
    }

    public var body: some View {
        let contrast = KanameContrastResolution.resolve(
            nativeColorSchemeContrast: colorSchemeContrast,
            accessibilityPreferences: accessibilityPreferences
        )
        HStack(spacing: KanameSpacing.xSmall) {
            Image(systemName: presentation.symbolName)
                .foregroundStyle(presentation.tone.color)
                .accessibilityHidden(true)
            Text(presentation.label)
                .foregroundStyle(KanameColor.textPrimary)
        }
            .font(density.font)
            .padding(.horizontal, density.horizontalPadding)
            .padding(.vertical, density.verticalPadding)
            .background(presentation.tone.color.opacity(contrast.fillOpacity), in: Capsule())
            .overlay {
                Capsule().stroke(
                    presentation.tone.color.opacity(contrast.strokeOpacity),
                    lineWidth: contrast.strokeWidth
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
    }
}

public struct KanameMetadataChip: View {
    private let label: String
    private let symbolName: String?
    private let accessibilityLabel: String
    private let density: KanameBadgeDensity
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.kanameAccessibilityPreferences) private var accessibilityPreferences

    public init(
        _ label: String,
        symbolName: String? = nil,
        accessibilityLabel: String? = nil,
        density: KanameBadgeDensity = .regular
    ) {
        self.label = label
        self.symbolName = symbolName
        self.accessibilityLabel = accessibilityLabel ?? label
        self.density = density
    }

    public var body: some View {
        let contrast = KanameContrastResolution.resolve(
            nativeColorSchemeContrast: colorSchemeContrast,
            accessibilityPreferences: accessibilityPreferences
        )
        HStack(spacing: KanameSpacing.xSmall) {
            if let symbolName {
                Image(systemName: symbolName)
                    .accessibilityHidden(true)
            }
            Text(label)
        }
        .font(density.font)
        .foregroundStyle(KanameColor.textSecondary)
        .padding(.horizontal, density.horizontalPadding)
        .padding(.vertical, density.verticalPadding)
        .background(KanameColor.raised.opacity(contrast.fillOpacity), in: Capsule())
        .overlay {
            Capsule().stroke(
                KanameColor.separator.opacity(contrast.strokeOpacity),
                lineWidth: contrast.strokeWidth
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

public struct KanameSectionHeader<Trailing: View>: View {
    private let title: String
    private let detail: String?
    private let trailing: Trailing

    public init(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: KanameSpacing.medium) {
            VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
                Text(title).font(KanameTypography.sectionTitle)
                if let detail {
                    Text(detail)
                        .font(KanameTypography.supporting)
                        .foregroundStyle(KanameColor.textSecondary)
                }
            }
            Spacer(minLength: KanameSpacing.large)
            trailing
        }
    }
}

public extension KanameSectionHeader where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil) {
        self.init(title, detail: detail) { EmptyView() }
    }
}

public struct KanameCallout: View {
    private let title: String
    private let message: String
    private let tone: KanameStatusTone

    public init(_ title: String, message: String, tone: KanameStatusTone = .informational) {
        self.title = title
        self.message = message
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .top, spacing: KanameSpacing.medium) {
            Image(systemName: tone.symbolName)
                .foregroundStyle(tone.color)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(KanameColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(KanameSpacing.medium)
        .background(tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous)
                .stroke(tone.color.opacity(0.36), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

public struct KanameEmptyState: View {
    private let title: String
    private let message: String
    private let symbolName: String

    public init(_ title: String, message: String, symbolName: String) {
        self.title = title
        self.message = message
        self.symbolName = symbolName
    }

    public var body: some View {
        VStack(spacing: KanameSpacing.medium) {
            Image(systemName: symbolName)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(KanameColor.textTertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(KanameColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(KanameSpacing.xxxLarge)
        .accessibilityElement(children: .combine)
    }
}

public struct KanameSyntheticDataBanner: View {
    public init() {}

    public var body: some View {
        Label(
            "Synthetic preview · no private account, repository, message, or collaborator data",
            systemImage: "sparkles.rectangle.stack.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(KanameColor.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, KanameSpacing.small)
        .background(KanameColor.external.opacity(0.24))
        .accessibilityElement(children: .combine)
    }
}

public struct KanameAuthorityBoundaryCard: View {
    private let title: String
    private let detail: String

    public init(
        title: String = "Host-controlled boundary",
        detail: String = "Collaborators can see and respond only to material deliberately shared with this Link space."
    ) {
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        KanameCallout(title, message: detail, tone: .external)
    }
}

public enum KanameMessageParticipantRole: String, Codable, Sendable {
    case user
    case assistant
    case host
    case collaborator

    var marker: String {
        switch self {
        case .user: "You"
        case .assistant: "Kaname assistant"
        case .host: "Host"
        case .collaborator: "You · external collaborator"
        }
    }

    var isLocalPrincipal: Bool {
        self == .user || self == .collaborator
    }

    public var presentation: KanameStatusPresentation {
        let label: String
        let tone: KanameStatusTone
        let accessibilityLabel: String
        switch self {
        case .user:
            (label, tone, accessibilityLabel) = ("User", .informational, "Participant: User")
        case .assistant:
            (label, tone, accessibilityLabel) = ("Kaname assistant", .informational, "Participant: Kaname assistant")
        case .host:
            (label, tone, accessibilityLabel) = ("Host", .informational, "Participant: Host")
        case .collaborator:
            (label, tone, accessibilityLabel) = (
                "External collaborator",
                .external,
                "Participant: External collaborator"
            )
        }
        return KanameStatusPresentation(
            label: label,
            tone: tone,
            symbolName: tone.symbolName,
            accessibilityLabel: accessibilityLabel
        )
    }
}

public enum KanameReceiptState: String, Codable, Sendable {
    case localStored
    case queued
    case gatewayAccepted
    case published
    case delivered
    case failed
    case outcomeUncertain

    public var label: String {
        switch self {
        case .localStored: "Stored locally"
        case .queued: "Queued locally"
        case .gatewayAccepted: "Received by host"
        case .published: "Published by host"
        case .delivered: "Delivered"
        case .failed: "Observed failure"
        case .outcomeUncertain: "Outcome uncertain"
        }
    }

    var tone: KanameStatusTone {
        switch self {
        case .localStored: .informational
        case .queued: .active
        case .gatewayAccepted: .informational
        case .published: .external
        case .delivered: .success
        case .failed: .danger
        case .outcomeUncertain: .warning
        }
    }
}

public struct KanameMessageReceipt: Equatable, Sendable {
    public let state: KanameReceiptState

    public init(state: KanameReceiptState) {
        self.state = state
    }

    public var label: String { state.label }

    public var presentation: KanameStatusPresentation {
        KanameStatusPresentation(
            label: state.label,
            tone: state.tone,
            symbolName: state.tone.symbolName,
            accessibilityLabel: "Message status: \(state.label)"
        )
    }
}

public struct KanameMessageBubble: View {
    private let author: String
    private let bodyText: String
    private let role: KanameMessageParticipantRole
    private let participantPresentation: KanameStatusPresentation
    private let receiptPresentation: KanameStatusPresentation?

    public init(
        author: String,
        body: String,
        role: KanameMessageParticipantRole,
        participantPresentation: KanameStatusPresentation? = nil,
        receipt: KanameMessageReceipt? = nil,
        receiptPresentation: KanameStatusPresentation? = nil
    ) {
        self.author = author
        self.bodyText = body
        self.role = role
        self.participantPresentation = participantPresentation ?? role.presentation
        self.receiptPresentation = receipt.map { receiptPresentation ?? $0.presentation }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: KanameSpacing.small) {
            HStack {
                Text(author).font(.caption.weight(.bold))
                Spacer()
                Text(role.marker)
                    .font(.caption2)
                    .foregroundStyle(KanameColor.textSecondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(participantPresentation.accessibilityLabel)
            }
            Text(bodyText)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let receiptPresentation {
                Label(receiptPresentation.label, systemImage: receiptPresentation.symbolName)
                    .font(.caption)
                    .foregroundStyle(receiptPresentation.tone.color)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(receiptPresentation.accessibilityLabel)
            }
        }
        .padding(KanameSpacing.medium)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            role.isLocalPrincipal ? KanameColor.selected : KanameColor.raised,
            in: RoundedRectangle(cornerRadius: KanameRadius.card, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}

public enum KanameApprovalState: String, Codable, Sendable {
    case proposed
    case working
    case changesRequested
    case approved
    case rejected
    case expired
    case outcomeUncertain

    var label: String {
        switch self {
        case .proposed: "Approval required"
        case .working: "Applying decision"
        case .changesRequested: "Changes requested"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .expired: "Expired"
        case .outcomeUncertain: "Outcome uncertain"
        }
    }

    var tone: KanameStatusTone {
        switch self {
        case .proposed: .attention
        case .working: .active
        case .changesRequested: .attention
        case .approved: .success
        case .rejected: .danger
        case .expired: .blocked
        case .outcomeUncertain: .warning
        }
    }

    var acceptsDecision: Bool { self == .proposed }
}

public struct KanameApprovalCard: View {
    private let title: String
    private let impact: String
    private let boundary: String
    private let state: KanameApprovalState
    private let onRequestChanges: () -> Void
    private let onReject: () -> Void
    private let onApprove: () -> Void

    public init(
        title: String,
        impact: String,
        boundary: String,
        state: KanameApprovalState = .proposed,
        onRequestChanges: @escaping () -> Void,
        onReject: @escaping () -> Void,
        onApprove: @escaping () -> Void
    ) {
        self.title = title
        self.impact = impact
        self.boundary = boundary
        self.state = state
        self.onRequestChanges = onRequestChanges
        self.onReject = onReject
        self.onApprove = onApprove
    }

    public var body: some View {
        KanameSurface {
            VStack(alignment: .leading, spacing: KanameSpacing.medium) {
                HStack(alignment: .top) {
                    Label(title, systemImage: "checkmark.shield.fill")
                        .font(.headline)
                    Spacer()
                    KanameStatusBadge(state.label, tone: state.tone)
                }
                Text(impact)
                    .font(.subheadline)
                    .foregroundStyle(KanameColor.textSecondary)
                KanameCallout("Authority boundary", message: boundary, tone: .warning)
                HStack {
                    Button("Request changes", action: onRequestChanges)
                        .disabled(!state.acceptsDecision)
                    Spacer()
                    Button("Reject", role: .destructive, action: onReject)
                        .disabled(!state.acceptsDecision)
                    Button("Approve", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.acceptsDecision)
                }
            }
        }
    }
}

public struct KanameMetricCard: View {
    private let label: String
    private let value: String
    private let detail: String
    private let tone: KanameStatusTone

    public init(_ label: String, value: String, detail: String, tone: KanameStatusTone = .informational) {
        self.label = label
        self.value = value
        self.detail = detail
        self.tone = tone
    }

    public var body: some View {
        KanameSurface {
            VStack(alignment: .leading, spacing: KanameSpacing.small) {
                Text(label.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(KanameColor.textSecondary)
                Text(value)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(tone.color)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(KanameColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

public extension View {
    func kanameMinimumInteractiveTarget() -> some View {
        frame(minWidth: KanameSize.minimumInteractiveTarget, minHeight: KanameSize.minimumInteractiveTarget)
            .contentShape(Rectangle())
    }

    func kanameCanvas() -> some View {
        foregroundStyle(KanameColor.textPrimary)
            .background(KanameColor.canvas)
    }
}
