import Foundation

/// A provider-neutral category for one observed provider tool call. Raw inputs,
/// outputs, and results remain in the sealed provider evidence instead of being
/// copied into the portable workspace model.
public enum ProviderToolKind: String, Codable, Equatable, Sendable {
    case commandExecution
    case fileChange
    case mcp
    case dynamic
    case collaboration
    case webSearch
    case imageGeneration
    case imageView
    case unknown
}

/// The lifecycle state reported by the provider. `observed` is used when an
/// adapter exposes a terminal tool record without a trustworthy start state.
public enum ProviderToolState: String, Codable, Equatable, Sendable {
    case observed
    case running
    case completed
    case failed
    case declined
    case interrupted
}

public struct ProviderToolObservation: Codable, Equatable, Sendable {
    public let callID: String
    public let parentCallID: String?
    public let kind: ProviderToolKind
    public let state: ProviderToolState
    public let name: String?

    public init(
        callID: String,
        parentCallID: String? = nil,
        kind: ProviderToolKind,
        state: ProviderToolState,
        name: String? = nil
    ) {
        self.callID = String(callID.prefix(512))
        self.parentCallID = parentCallID.map { String($0.prefix(512)) }
        self.kind = kind
        self.state = state
        self.name = name.map { String($0.prefix(512)) }
    }
}

public enum ProviderAgentActivityKind: String, Codable, Equatable, Sendable {
    case started
    case interacted
    case completed
    case failed
    case interrupted
}

/// A typed observation of provider-owned child-agent activity. `agentID` is
/// native provider identity; Kaname derives its own stable record ID when the
/// observation enters desktop storage.
public struct ProviderAgentActivity: Codable, Equatable, Sendable {
    public let agentID: String
    public let parentAgentID: String?
    public let activity: ProviderAgentActivityKind
    public let agentPath: String?
    public let taskType: String?
    public let sourceToolCallID: String?

    public init(
        agentID: String,
        parentAgentID: String? = nil,
        activity: ProviderAgentActivityKind,
        agentPath: String? = nil,
        taskType: String? = nil,
        sourceToolCallID: String? = nil
    ) {
        self.agentID = String(agentID.prefix(512))
        self.parentAgentID = parentAgentID.map { String($0.prefix(512)) }
        self.activity = activity
        self.agentPath = agentPath.map { String($0.prefix(1_024)) }
        self.taskType = taskType.map { String($0.prefix(512)) }
        self.sourceToolCallID = sourceToolCallID.map { String($0.prefix(512)) }
    }
}

/// Folds repeated provider observations into the child agents whose terminal
/// state is still unknown. It preserves only bounded typed metadata.
public struct ProviderAgentActivityLedger: Sendable {
    private var activityByAgentID: [String: ProviderAgentActivity] = [:]

    public init() {}

    public var hasOutstandingActivity: Bool {
        !activityByAgentID.isEmpty
    }

    public var outstandingActivities: [ProviderAgentActivity] {
        activityByAgentID.values.sorted { $0.agentID < $1.agentID }
    }

    public mutating func observe(_ activity: ProviderAgentActivity?) {
        guard let activity else { return }
        switch activity.activity {
        case .started, .interacted:
            activityByAgentID[activity.agentID] = activity
        case .completed, .failed, .interrupted:
            activityByAgentID.removeValue(forKey: activity.agentID)
        }
    }

    public func settlementActivities(
        as terminalActivity: ProviderAgentActivityKind
    ) -> [ProviderAgentActivity] {
        switch terminalActivity {
        case .completed, .failed, .interrupted:
            outstandingActivities.map {
                ProviderAgentActivity(
                    agentID: $0.agentID,
                    parentAgentID: $0.parentAgentID,
                    activity: terminalActivity,
                    agentPath: $0.agentPath,
                    taskType: $0.taskType,
                    sourceToolCallID: $0.sourceToolCallID
                )
            }
        case .started, .interacted:
            []
        }
    }
}
