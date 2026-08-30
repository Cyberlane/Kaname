import KanameDomain

public enum ProviderConversationDriver: Equatable, Sendable {
    case codex
    case native(NativeConversationDriver)
}

public enum ProviderProbeSupport: String, Codable, Sendable {
    case codexAppServer
    case claudeVersion
    case openCodeEndpoint
    case sharedVersion
}

/// Connectivity-owned provider metadata. Presentation layers may decorate a
/// provider by `id`, but symbols and colors deliberately do not belong here.
public struct ProviderInventoryEntry: Equatable, Sendable {
    public let id: ProviderDriverKind
    public let defaultInstanceID: ProviderInstanceID
    public let displayName: String
    public let executableCandidates: [String]
    public let conversationDriver: ProviderConversationDriver
    public let probeSupport: ProviderProbeSupport
    public let declaredVersionRange: ProviderVersionRange?
    public let capabilityClaims: Set<ProviderCapabilityClaim>
    let versionProbeDetail: String?

    public var defaultInstance: ProviderInstance {
        ProviderInstance(id: defaultInstanceID, driver: id, displayName: displayName)
    }
}

public enum ProviderInventory {
    public static let providers: [ProviderInventoryEntry] = [
        ProviderInventoryEntry(
            id: .codex,
            defaultInstanceID: ProviderInstanceID(rawValue: "codexLocal")!,
            displayName: "Codex",
            executableCandidates: ["codex"],
            conversationDriver: .codex,
            probeSupport: .codexAppServer,
            declaredVersionRange: nil,
            capabilityClaims: [
                .conversation, .imageAttachments, .modelDiscovery, .modelSelection,
                .reasoningEffort, .resumableSessions, .skillDiscovery, .toolEventStreaming,
            ],
            versionProbeDetail: nil
        ),
        ProviderInventoryEntry(
            id: .claudeAgent,
            defaultInstanceID: ProviderInstanceID(rawValue: "claudeLocal")!,
            displayName: "Claude",
            executableCandidates: ["claude"],
            conversationDriver: .native(.claude),
            probeSupport: .claudeVersion,
            declaredVersionRange: nil,
            capabilityClaims: [
                .conversation, .imageAttachments, .modelSelection, .reasoningEffort,
                .resumableSessions, .toolEventStreaming,
            ],
            // ClaudeCapabilityProbe still owns its fallback detail until its
            // provider-specific P6.2b slice; do not duplicate that text here.
            versionProbeDetail: nil
        ),
        ProviderInventoryEntry(
            id: .openCode,
            defaultInstanceID: ProviderInstanceID(rawValue: "opencodeLocal")!,
            displayName: "OpenCode",
            executableCandidates: ["opencode"],
            conversationDriver: .native(.openCode),
            probeSupport: .openCodeEndpoint,
            declaredVersionRange: nil,
            capabilityClaims: [
                .conversation, .imageAttachments, .modelDiscovery, .modelSelection,
                .reasoningEffort, .resumableSessions, .skillDiscovery, .toolEventStreaming,
            ],
            versionProbeDetail: nil
        ),
        ProviderInventoryEntry(
            id: .cursorAgent,
            defaultInstanceID: ProviderInstanceID(rawValue: "cursorLocal")!,
            displayName: "Cursor",
            executableCandidates: ["cursor-agent", "agent"],
            conversationDriver: .native(.cursor),
            probeSupport: .sharedVersion,
            declaredVersionRange: nil,
            capabilityClaims: [
                .conversation, .imageAttachments, .modelSelection, .resumableSessions,
                .toolEventStreaming,
            ],
            versionProbeDetail: "Cursor CLI is available. Conversation turns use print + stream-json; authentication was not probed and no prompt was sent."
        ),
        ProviderInventoryEntry(
            id: .grokBuild,
            defaultInstanceID: ProviderInstanceID(rawValue: "grokLocal")!,
            displayName: "Grok",
            executableCandidates: ["grok"],
            conversationDriver: .native(.grok),
            probeSupport: .sharedVersion,
            declaredVersionRange: nil,
            capabilityClaims: [
                .conversation, .modelSelection, .resumableSessions, .toolEventStreaming,
            ],
            versionProbeDetail: "Grok Build CLI is available. Conversation turns use headless --single + streaming-messages-json; authentication was not probed and no prompt was sent."
        ),
    ]

    public static func provider(id: ProviderDriverKind) -> ProviderInventoryEntry? {
        providers.first { $0.id == id }
    }

    public static func provider(conversationDriver: ProviderConversationDriver) -> ProviderInventoryEntry? {
        providers.first { $0.conversationDriver == conversationDriver }
    }
}
