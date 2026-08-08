import Foundation

public enum EventKind: String, CaseIterable, Codable, Sendable {
    case taskQueued
    case runStarting
    case runStarted
    case approvalRequested
    case approvalApproved
    case approvalRejected
    case providerCompleted
    case workAccepted
    case runFailed
    case runCancelled
    case runInterrupted
    case nativeProviderEvent
}

public struct EventOrigin: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case synthetic
        case provider
        case controlPlane
    }

    public let kind: Kind
    public let provider: String?
    public let nativeType: String?
    public let rawPayload: Data?

    public init(
        kind: Kind,
        provider: String? = nil,
        nativeType: String? = nil,
        rawPayload: Data? = nil
    ) {
        self.kind = kind
        self.provider = provider
        self.nativeType = nativeType
        self.rawPayload = rawPayload
    }
}

public struct EventEnvelope: Codable, Equatable, Sendable {
    public let id: KanameID
    public let streamID: KanameID
    public let sequence: UInt64
    public let occurredAt: Date
    public let kind: EventKind
    public let taskID: KanameID?
    public let runID: KanameID?
    public let approvalID: KanameID?
    public let origin: EventOrigin

    public init(
        id: KanameID,
        streamID: KanameID,
        sequence: UInt64,
        occurredAt: Date,
        kind: EventKind,
        taskID: KanameID? = nil,
        runID: KanameID? = nil,
        approvalID: KanameID? = nil,
        origin: EventOrigin
    ) {
        self.id = id
        self.streamID = streamID
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.kind = kind
        self.taskID = taskID
        self.runID = runID
        self.approvalID = approvalID
        self.origin = origin
    }
}
