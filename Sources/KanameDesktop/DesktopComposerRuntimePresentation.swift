import KanameDomain

public enum DesktopComposerRuntimeControl: String, Equatable, Sendable {
    case providerAndModel
    case thinking
    case access
    case overflow
}

public struct DesktopComposerRuntimeLayout: Equatable, Sendable {
    public let visibleControls: [DesktopComposerRuntimeControl]
    public let overflowControls: [DesktopComposerRuntimeControl]

    public init(
        visibleControls: [DesktopComposerRuntimeControl],
        overflowControls: [DesktopComposerRuntimeControl]
    ) {
        self.visibleControls = visibleControls
        self.overflowControls = overflowControls
    }
}

public enum DesktopComposerAccessPresentation: Equatable, Sendable {
    case supervised
    case autoAcceptEdits
    case automatic
    case fullAccess

    public var title: String { values.title }
    public var detail: String { values.detail }
    public var systemImage: String { values.systemImage }
    public var isWarning: Bool { values.isWarning }

    private var values: (title: String, detail: String, systemImage: String, isWarning: Bool) {
        switch self {
        case .supervised:
            ("Supervised", "Ask before commands and file changes.", "checkmark.shield", false)
        case .autoAcceptEdits:
            ("Auto-accept edits", "Apply workspace edits; ask before escalation.", "pencil.and.outline", false)
        case .automatic:
            ("Auto", "Approve routine actions automatically.", "bolt.shield", false)
        case .fullAccess:
            ("Full access", "Commands, files, and network without prompts.", "exclamationmark.shield.fill", true)
        }
    }
}

public enum DesktopComposerRuntimePresentation {
    public static let compactWidthThreshold = 520.0

    public static func layout(
        for kind: DesktopWorkKind,
        availableWidth: Double
    ) -> DesktopComposerRuntimeLayout {
        layout(for: kind, compact: availableWidth < compactWidthThreshold)
    }

    public static func layout(
        for kind: DesktopWorkKind,
        compact: Bool
    ) -> DesktopComposerRuntimeLayout {
        if compact {
            let overflow: [DesktopComposerRuntimeControl] = kind == .coding
                ? [.thinking]
                : [.thinking, .access]
            return DesktopComposerRuntimeLayout(
                visibleControls: [.providerAndModel, .overflow],
                overflowControls: overflow
            )
        }

        let visible: [DesktopComposerRuntimeControl] = kind == .coding
            ? [.providerAndModel, .thinking]
            : [.providerAndModel, .thinking, .access]
        return DesktopComposerRuntimeLayout(visibleControls: visible, overflowControls: [])
    }

    public static func providerSystemImage(_ provider: String) -> String {
        switch provider.lowercased() {
        case "codex": "terminal.fill"
        case "claude": "sparkles"
        case "opencode", "open code": "chevron.left.forwardslash.chevron.right"
        default: "cpu"
        }
    }

    public static func access(_ mode: ConversationRuntimeMode) -> DesktopComposerAccessPresentation {
        switch mode {
        case .approvalRequired:
            .supervised
        case .autoAcceptEdits:
            .autoAcceptEdits
        case .auto:
            .automatic
        case .fullAccess:
            .fullAccess
        }
    }
}
