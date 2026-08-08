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

    public init(id: String, displayName: String, isDefault: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
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
        self.state = state
        self.installed = installed
        self.version = version
        self.authentication = authentication
        self.models = models
        self.skills = skills
        self.checkedAt = checkedAt
        self.detail = detail
    }
}
