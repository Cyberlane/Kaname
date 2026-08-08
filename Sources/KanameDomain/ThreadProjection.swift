import Foundation

public enum ProjectionError: Error, Equatable, Sendable {
    case sequenceMustIncrease(previous: UInt64, received: UInt64)
}

public struct ThreadProjection: Equatable, Sendable {
    public let threadID: KanameID
    public private(set) var taskState: TaskState
    public private(set) var attention: AttentionState
    public private(set) var pendingApprovalIDs: Set<KanameID>
    public private(set) var latestSequence: UInt64?

    public init(threadID: KanameID) {
        self.threadID = threadID
        self.taskState = .notStarted
        self.attention = .none
        self.pendingApprovalIDs = []
        self.latestSequence = nil
    }

    public mutating func apply(_ event: EventEnvelope) throws {
        if let latestSequence, event.sequence <= latestSequence {
            throw ProjectionError.sequenceMustIncrease(
                previous: latestSequence,
                received: event.sequence
            )
        }

        switch event.kind {
        case .taskQueued:
            taskState = .queued
        case .runStarting:
            taskState = .starting
        case .runStarted:
            taskState = .running
        case .approvalRequested:
            if let approvalID = event.approvalID {
                pendingApprovalIDs.insert(approvalID)
            }
            taskState = .waitingForUser
        case .approvalApproved, .approvalRejected:
            if let approvalID = event.approvalID {
                pendingApprovalIDs.remove(approvalID)
            }
            taskState = pendingApprovalIDs.isEmpty ? .running : .waitingForUser
        case .providerCompleted:
            taskState = .completed
        case .workAccepted:
            taskState = .accepted
        case .runFailed:
            taskState = .failed
        case .runCancelled:
            taskState = .cancelled
        case .runInterrupted:
            taskState = .interrupted
        case .nativeProviderEvent:
            break
        }

        latestSequence = event.sequence
        attention = Self.attention(for: taskState)
    }

    private static func attention(for state: TaskState) -> AttentionState {
        switch state {
        case .notStarted, .accepted, .cancelled:
            .none
        case .queued:
            .queued
        case .starting, .running:
            .running
        case .waitingForUser:
            .needsResponse
        case .completed:
            .needsReview
        case .failed:
            .failed
        case .interrupted:
            .interrupted
        }
    }
}
