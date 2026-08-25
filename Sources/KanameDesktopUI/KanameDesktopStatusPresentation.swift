import KanameDesignSystem
import KanameDesktop
import KanameLinkHost

/// Product-domain adapters keep status meaning exhaustive and independent from
/// individual SwiftUI call sites.
public enum KanameDesktopStatusPresentation {
    public static func record(_ state: DesktopRecordState) -> KanameStatusPresentation {
        let tone: KanameStatusTone
        let symbolName: String
        switch state {
        case .ready:
            (tone, symbolName) = (.success, "checkmark.circle")
        case .draft:
            (tone, symbolName) = (.neutral, "pencil.circle")
        case .proposed:
            (tone, symbolName) = (.informational, "lightbulb")
        case .paused:
            (tone, symbolName) = (.neutral, "pause.circle")
        case .disconnected:
            (tone, symbolName) = (.warning, "bolt.slash")
        case .needsReview:
            (tone, symbolName) = (.attention, "eye.circle")
        case .waiting:
            (tone, symbolName) = (.informational, "clock")
        case .running:
            (tone, symbolName) = (.active, "progress.indicator")
        case .failed:
            (tone, symbolName) = (.danger, "exclamationmark.triangle")
        }
        return KanameStatusPresentation(
            label: state.label,
            tone: tone,
            symbolName: symbolName,
            accessibilityLabel: "Status: \(state.label)"
        )
    }

    public static func action(_ state: DesktopActionState) -> KanameStatusPresentation {
        let tone: KanameStatusTone
        let symbolName: String
        switch state {
        case .proposed:
            (tone, symbolName) = (.informational, "lightbulb")
        case .awaitingApproval:
            (tone, symbolName) = (.attention, "checkmark.shield")
        case .approved:
            (tone, symbolName) = (.success, "hand.thumbsup")
        case .rejected:
            (tone, symbolName) = (.danger, "hand.thumbsdown")
        case .running:
            (tone, symbolName) = (.active, "progress.indicator")
        case .completed:
            (tone, symbolName) = (.success, "checkmark.circle")
        case .failed:
            (tone, symbolName) = (.danger, "exclamationmark.triangle")
        case .interrupted:
            (tone, symbolName) = (.blocked, "stop.circle")
        case .reconciled:
            (tone, symbolName) = (.success, "checkmark.circle")
        case .cancelled:
            (tone, symbolName) = (.neutral, "xmark.circle")
        }
        return KanameStatusPresentation(
            label: state.label,
            tone: tone,
            symbolName: symbolName,
            accessibilityLabel: "Action status: \(state.label)"
        )
    }

    public static func attention(_ state: DesktopAttention) -> KanameStatusPresentation {
        let tone: KanameStatusTone
        let symbolName: String
        switch state {
        case .needsResponse:
            (tone, symbolName) = (.attention, "bubble.left")
        case .needsApproval:
            (tone, symbolName) = (.attention, "checkmark.shield")
        case .needsInput:
            (tone, symbolName) = (.attention, "questionmark.bubble")
        case .running:
            (tone, symbolName) = (.active, "progress.indicator")
        case .queued:
            (tone, symbolName) = (.informational, "clock")
        case .completed:
            (tone, symbolName) = (.success, "checkmark.circle")
        case .failed:
            (tone, symbolName) = (.danger, "exclamationmark.triangle")
        case .archived:
            (tone, symbolName) = (.neutral, "archivebox")
        }
        return KanameStatusPresentation(
            label: state.label,
            tone: tone,
            symbolName: symbolName,
            accessibilityLabel: "Attention: \(state.label)"
        )
    }

    public static func workflow(_ state: DesktopWorkflowWorkState) -> KanameStatusPresentation {
        let tone: KanameStatusTone
        let symbolName: String
        switch state {
        case .open:
            (tone, symbolName) = (.neutral, "circle")
        case .preparing:
            (tone, symbolName) = (.active, "hourglass")
        case .running:
            (tone, symbolName) = (.active, "waveform.path.ecg")
        case .needsAttention:
            (tone, symbolName) = (.attention, "exclamationmark.triangle.fill")
        case .readyForEffect:
            (tone, symbolName) = (.attention, "checkmark.shield")
        case .waitingExternal:
            (tone, symbolName) = (.external, "envelope.badge")
        case .accepted:
            (tone, symbolName) = (.success, "checkmark.seal.fill")
        case .operationallyClosed:
            (tone, symbolName) = (.neutral, "archivebox.fill")
        case .failed:
            (tone, symbolName) = (.danger, "xmark.octagon.fill")
        case .cancelled:
            (tone, symbolName) = (.blocked, "slash.circle")
        case .superseded:
            (tone, symbolName) = (.neutral, "arrow.uturn.forward.circle")
        }
        return KanameStatusPresentation(
            label: state.label,
            tone: tone,
            symbolName: symbolName,
            accessibilityLabel: "Workflow status: \(state.label)"
        )
    }
}

public enum KanameDesktopLinkStatusPresentation {
    public static let linkOnly = KanameStatusPresentation(
        label: "Link only",
        tone: .informational,
        symbolName: "link",
        accessibilityLabel: "Scope: Link only"
    )

    public static let externalDevice = KanameStatusPresentation(
        label: "External device",
        tone: .attention,
        symbolName: "person.crop.circle.badge.questionmark",
        accessibilityLabel: "Approval required: external device"
    )

    public static let externalUntrusted = KanameStatusPresentation(
        label: "External · untrusted",
        tone: .external,
        symbolName: "exclamationmark.shield.fill",
        accessibilityLabel: "Trust boundary: external, untrusted"
    )

    public static func externalMessages(_ count: Int) -> KanameStatusPresentation {
        KanameStatusPresentation(
            label: "\(count) external",
            tone: .attention,
            symbolName: "envelope.badge",
            accessibilityLabel: "\(count) external message\(count == 1 ? "" : "s") \(count == 1 ? "needs" : "need") attention"
        )
    }

    public static func gateway(_ lifecycle: KanameLinkGatewayLifecycle) -> KanameStatusPresentation {
        let label: String
        let tone: KanameStatusTone
        let symbolName: String
        switch lifecycle {
        case .offline:
            (label, tone, symbolName) = ("Offline", .warning, "bolt.slash.fill")
        case .connecting:
            (label, tone, symbolName) = ("Connecting", .active, "arrow.triangle.2.circlepath")
        case .ready:
            (label, tone, symbolName) = ("Ready", .success, "checkmark.shield.fill")
        case .degraded:
            (label, tone, symbolName) = ("Degraded", .warning, "exclamationmark.triangle.fill")
        }
        return KanameStatusPresentation(
            label: label,
            tone: tone,
            symbolName: symbolName,
            accessibilityLabel: "Gateway status: \(label)"
        )
    }

    public static func publication(_ state: KanameLinkPublicationState) -> KanameStatusPresentation {
        let label: String
        let tone: KanameStatusTone
        let symbolName: String
        switch state {
        case .preview:
            (label, tone, symbolName) = ("Preview", .neutral, "eye.fill")
        case .gatewayAccepted:
            (label, tone, symbolName) = ("Gateway accepted", .success, "checkmark.seal.fill")
        case .withdrawn:
            (label, tone, symbolName) = ("Withdrawn", .neutral, "nosign")
        }
        return KanameStatusPresentation(
            label: label,
            tone: tone,
            symbolName: symbolName,
            accessibilityLabel: "Publication status: \(label)"
        )
    }

    public static func receipt(_ stage: KanameLinkReceiptStage) -> KanameStatusPresentation {
        let label: String
        let tone: KanameStatusTone
        let symbolName: String
        switch stage {
        case .savedLocally:
            (label, tone, symbolName) = ("Saved locally", .informational, "internaldrive.fill")
        case .gatewayAccepted:
            (label, tone, symbolName) = ("Gateway accepted", .informational, "checkmark.seal.fill")
        case .relayAccepted:
            (label, tone, symbolName) = ("Relay accepted", .active, "network")
        case .delivered:
            (label, tone, symbolName) = ("Delivered", .success, "checkmark.circle.fill")
        case .opened:
            (label, tone, symbolName) = ("Opened", .success, "eye.fill")
        case .failed:
            (label, tone, symbolName) = ("Failed", .danger, "exclamationmark.triangle.fill")
        }
        return KanameStatusPresentation(
            label: label,
            tone: tone,
            symbolName: symbolName,
            accessibilityLabel: "Receipt status: \(label)"
        )
    }
}
