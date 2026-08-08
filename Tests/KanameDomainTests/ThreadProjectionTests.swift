import Foundation
import Testing
@testable import KanameDomain
import KanameFixtures

struct ThreadProjectionTests {
    private let threadID = KanameID(rawValue: "thread-phase0")
    private let taskID = KanameID(rawValue: "task-phase0")
    private let runID = KanameID(rawValue: "run-phase0")
    private let approvalID = KanameID(rawValue: "approval-phase0")

    @Test
    func providerCompletionRequiresSeparateAcceptance() throws {
        var projection = ThreadProjection(threadID: threadID)

        try projection.apply(event(sequence: 1, kind: .taskQueued))
        try projection.apply(event(sequence: 2, kind: .runStarted))
        try projection.apply(event(sequence: 3, kind: .providerCompleted))

        #expect(projection.taskState == .completed)
        #expect(projection.attention == .needsReview)

        try projection.apply(event(sequence: 4, kind: .workAccepted))

        #expect(projection.taskState == .accepted)
        #expect(projection.attention == .none)
    }

    @Test
    func approvalRequiresAttentionUntilItIsResolved() throws {
        var projection = ThreadProjection(threadID: threadID)

        try projection.apply(event(sequence: 1, kind: .taskQueued))
        try projection.apply(event(sequence: 2, kind: .runStarted))
        try projection.apply(event(sequence: 3, kind: .approvalRequested, approvalID: approvalID))

        #expect(projection.taskState == .waitingForUser)
        #expect(projection.attention == .needsResponse)
        #expect(projection.pendingApprovalIDs == [approvalID])

        try projection.apply(event(sequence: 4, kind: .approvalApproved, approvalID: approvalID))

        #expect(projection.taskState == .running)
        #expect(projection.pendingApprovalIDs.isEmpty)
    }

    @Test
    func replayRejectsASequenceThatDoesNotAdvance() throws {
        var projection = ThreadProjection(threadID: threadID)

        try projection.apply(event(sequence: 3, kind: .taskQueued))

        #expect(throws: ProjectionError.sequenceMustIncrease(previous: 3, received: 3)) {
            try projection.apply(event(sequence: 3, kind: .runStarted))
        }
    }

    @Test
    func deterministicFixturesCoverReviewApprovalAndFailure() throws {
        let review = try Phase0Fixtures.codingReview.makeProjection()
        let waiting = try Phase0Fixtures.waitingForCalendarApproval.makeProjection()
        let failed = try Phase0Fixtures.failedResearch.makeProjection()

        #expect(review.attention == .needsReview)
        #expect(waiting.attention == .needsResponse)
        #expect(failed.attention == .failed)
        #expect(Phase0Fixtures.waitingForCalendarApproval.queueItems.count == 1)
    }

    private func event(
        sequence: UInt64,
        kind: EventKind,
        approvalID: KanameID? = nil
    ) -> EventEnvelope {
        EventEnvelope(
            id: KanameID(rawValue: "event-\(sequence)"),
            streamID: threadID,
            sequence: sequence,
            occurredAt: Date(timeIntervalSince1970: 1_762_000_000 + Double(sequence)),
            kind: kind,
            taskID: taskID,
            runID: runID,
            approvalID: approvalID,
            origin: EventOrigin(kind: .synthetic)
        )
    }
}
