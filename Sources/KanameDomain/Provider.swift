import Foundation

/// An open implementation identifier. A persisted instance can therefore survive a
/// newer driver arriving, or an older build missing a driver, without losing its
/// configuration.
public struct ProviderDriverKind: Codable, Comparable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let pattern = "^[A-Za-z][A-Za-z0-9_-]{0,63}$"
        guard rawValue.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        self.rawValue = rawValue
    }

    public static let codex = ProviderDriverKind(rawValue: "codex")!
    public static let claudeAgent = ProviderDriverKind(rawValue: "claudeAgent")!
    public static let openCode = ProviderDriverKind(rawValue: "opencode")!
    public static let cursorAgent = ProviderDriverKind(rawValue: "cursorAgent")!
    public static let grokBuild = ProviderDriverKind(rawValue: "grokBuild")!

    public static func < (lhs: ProviderDriverKind, rhs: ProviderDriverKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A user-defined routing key. Sessions and future event bindings refer to this
/// value, never directly to a driver kind, so two accounts for one provider remain
/// distinct.
public struct ProviderInstanceID: Codable, Comparable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard let validated = ProviderDriverKind(rawValue: rawValue) else {
            return nil
        }

        self.rawValue = validated.rawValue
    }

    public static func < (lhs: ProviderInstanceID, rhs: ProviderInstanceID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ProviderInstance: Codable, Equatable, Sendable {
    public let id: ProviderInstanceID
    public let driver: ProviderDriverKind
    public let displayName: String

    public init(id: ProviderInstanceID, driver: ProviderDriverKind, displayName: String) {
        self.id = id
        self.driver = driver
        self.displayName = displayName
    }
}

/// Adapter behavior that Kaname's local implementation currently exposes.
/// Claims describe the adapter contract only; they do not imply that a provider
/// is installed, authenticated, or qualified for a particular CLI version.
public enum ProviderCapabilityClaim: String, Codable, CaseIterable, Hashable, Sendable {
    case conversation
    case imageAttachments
    case modelDiscovery
    case modelSelection
    case reasoningEffort
    case resumableSessions
    case skillDiscovery
    case toolEventStreaming
}

/// A half-open CLI version interval backed by qualification evidence.
/// `nil` on an inventory entry means that no version interval has been qualified
/// yet; callers must not interpret a missing range as accepting every version.
public struct ProviderVersionRange: Codable, Equatable, Sendable {
    public let minimumInclusive: String
    public let maximumExclusive: String

    public init(minimumInclusive: String, maximumExclusive: String) {
        self.minimumInclusive = minimumInclusive
        self.maximumExclusive = maximumExclusive
    }
}

public enum ProviderConnectionState: String, Codable, Sendable {
    case ready
    case degraded
    case unavailable
    case authenticationRequired
    case unsupported
}

public enum ProviderAuthenticationState: String, Codable, Sendable {
    case authenticated
    case unauthenticated
    case unknown
}

public struct ProviderModel: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let isDefault: Bool
    public let supportedReasoningEfforts: [String]?
    public let defaultReasoningEffort: String?
    public init(id: String, displayName: String, isDefault: Bool = false, supportedReasoningEfforts: [String]? = nil, defaultReasoningEffort: String? = nil) {
        (self.id, self.displayName, self.isDefault, self.supportedReasoningEfforts, self.defaultReasoningEffort) = (id, displayName, isDefault, supportedReasoningEfforts, defaultReasoningEffort)
    }
}

/// A redacted, read-only view of what a native provider endpoint reported. It is
/// safe to render and persist as product state; credentials and raw provider
/// payloads deliberately do not belong here.
public struct ProviderCapabilitySnapshot: Codable, Equatable, Sendable {
    public let instance: ProviderInstance
    public let state: ProviderConnectionState
    public let installed: Bool
    public let version: String?
    public let authentication: ProviderAuthenticationState
    public let models: [ProviderModel]
    public let skills: [String]
    public let checkedAt: Date
    public let detail: String?

    public init(
        instance: ProviderInstance,
        state: ProviderConnectionState,
        installed: Bool,
        version: String? = nil,
        authentication: ProviderAuthenticationState,
        models: [ProviderModel] = [],
        skills: [String] = [],
        checkedAt: Date = .now,
        detail: String? = nil
    ) {
        self.instance = instance
        (self.state, self.installed) = (state, installed)
        self.version = version
        self.authentication = authentication
        (self.models, self.skills) = (models, skills)
        self.checkedAt = checkedAt
        self.detail = detail
    }
}
