import Foundation
import KanameDomain

public struct Phase0Fixture: Sendable {
    public let name: String
    public let thread: KanameDomain.Thread
    public let task: Task
    public let providerSession: ProviderSession
    public let run: Run
    public let approvals: [Approval]
    public let queueItems: [QueueItem]
    public let events: [EventEnvelope]

    public init(
        name: String,
        thread: KanameDomain.Thread,
        task: Task,
        providerSession: ProviderSession,
        run: Run,
        approvals: [Approval],
        queueItems: [QueueItem],
        events: [EventEnvelope]
    ) {
        self.name = name
        self.thread = thread
        self.task = task
        self.providerSession = providerSession
        self.run = run
        self.approvals = approvals
        self.queueItems = queueItems
        self.events = events
    }

    public func makeProjection() throws -> ThreadProjection {
        try events.reduce(into: ThreadProjection(threadID: thread.id)) { projection, event in
            try projection.apply(event)
        }
    }
}

public enum Phase0Fixtures {
    public static let codingReview = makeCodingReview()
    public static let waitingForCalendarApproval = makeWaitingForCalendarApproval()
    public static let waitingForEmailApproval = makeWaitingForEmailApproval()
    public static let runningCodingTask = makeRunningCodingTask()
    public static let failedResearch = makeFailedResearch()

    public static let all = [
        codingReview,
        waitingForCalendarApproval,
        waitingForEmailApproval,
        runningCodingTask,
        failedResearch,
    ]

    private static func makeCodingReview() -> Phase0Fixture {
        let threadID = KanameID(rawValue: "thread-coding-review")
        let taskID = KanameID(rawValue: "task-coding-review")
        let runID = KanameID(rawValue: "run-coding-review")
        let sessionID = KanameID(rawValue: "session-coding-review")
        let approvalID = KanameID(rawValue: "approval-coding-review")
        let startedAt = Date(timeIntervalSince1970: 1_762_000_000)

        return Phase0Fixture(
            name: "coding-review",
            thread: KanameDomain.Thread(
                id: threadID,
                title: "Add a focused search workflow",
                workspaceKind: .coding
            ),
            task: Task(id: taskID, threadID: threadID, title: "Add search workflow"),
            providerSession: ProviderSession(
                id: sessionID,
                provider: "Fake Provider",
                nativeSessionID: "fixture-session-coding-review"
            ),
            run: Run(id: runID, taskID: taskID, providerSessionID: sessionID),
            approvals: [
                Approval(
                    id: approvalID,
                    action: .codeChange,
                    status: .approved,
                    target: "isolated workspace",
                    consequence: "write a proposed implementation",
                    expiresAt: startedAt.addingTimeInterval(1_800)
                ),
            ],
            queueItems: [],
            events: [
                event(1, .taskQueued, threadID, taskID, runID, startedAt),
                event(2, .runStarted, threadID, taskID, runID, startedAt),
                event(
                    3,
                    .nativeProviderEvent,
                    threadID,
                    taskID,
                    runID,
                    startedAt,
                    origin: EventOrigin(
                        kind: .provider,
                        provider: "Fake Provider",
                        nativeType: "tool.started",
                        rawPayload: Data("{\"tool\":\"search_files\"}".utf8)
                    )
                ),
                event(4, .approvalRequested, threadID, taskID, runID, startedAt, approvalID: approvalID),
                event(5, .approvalApproved, threadID, taskID, runID, startedAt, approvalID: approvalID),
                event(6, .providerCompleted, threadID, taskID, runID, startedAt),
            ]
        )
    }

    private static func makeWaitingForCalendarApproval() -> Phase0Fixture {
        let threadID = KanameID(rawValue: "thread-calendar-approval")
        let taskID = KanameID(rawValue: "task-calendar-approval")
        let runID = KanameID(rawValue: "run-calendar-approval")
        let sessionID = KanameID(rawValue: "session-calendar-approval")
        let approvalID = KanameID(rawValue: "approval-calendar-approval")
        let startedAt = Date(timeIntervalSince1970: 1_762_100_000)

        return Phase0Fixture(
            name: "waiting-for-calendar-approval",
            thread: KanameDomain.Thread(
                id: threadID,
                title: "Reschedule a calendar event",
                workspaceKind: .calendar
            ),
            task: Task(id: taskID, threadID: threadID, title: "Reschedule event"),
            providerSession: ProviderSession(id: sessionID, provider: "Fake Provider"),
            run: Run(id: runID, taskID: taskID, providerSessionID: sessionID),
            approvals: [
                Approval(
                    id: approvalID,
                    action: .modifyCalendar,
                    status: .pending,
                    target: "selected calendar event",
                    consequence: "change the event time for all attendees",
                    expiresAt: startedAt.addingTimeInterval(900)
                ),
            ],
            queueItems: [
                QueueItem(
                    id: KanameID(rawValue: "queue-calendar-follow-up"),
                    threadID: threadID,
                    position: 1,
                    body: "Please preserve the existing attendees.",
                    createdAt: startedAt.addingTimeInterval(30)
                ),
            ],
            events: [
                event(1, .taskQueued, threadID, taskID, runID, startedAt),
                event(2, .runStarted, threadID, taskID, runID, startedAt),
                event(3, .approvalRequested, threadID, taskID, runID, startedAt, approvalID: approvalID),
            ]
        )
    }

    private static func makeFailedResearch() -> Phase0Fixture {
        let threadID = KanameID(rawValue: "thread-failed-research")
        let taskID = KanameID(rawValue: "task-failed-research")
        let runID = KanameID(rawValue: "run-failed-research")
        let sessionID = KanameID(rawValue: "session-failed-research")
        let startedAt = Date(timeIntervalSince1970: 1_762_200_000)

        return Phase0Fixture(
            name: "failed-research",
            thread: KanameDomain.Thread(
                id: threadID,
                title: "Compare provider streaming support",
                workspaceKind: .research
            ),
            task: Task(id: taskID, threadID: threadID, title: "Compare streaming support"),
            providerSession: ProviderSession(id: sessionID, provider: "Fake Provider"),
            run: Run(id: runID, taskID: taskID, providerSessionID: sessionID),
            approvals: [],
            queueItems: [],
            events: [
                event(1, .taskQueued, threadID, taskID, runID, startedAt),
                event(2, .runStarted, threadID, taskID, runID, startedAt),
                event(3, .runFailed, threadID, taskID, runID, startedAt),
            ]
        )
    }

    private static func makeWaitingForEmailApproval() -> Phase0Fixture {
        let threadID = KanameID(rawValue: "thread-email-approval")
        let taskID = KanameID(rawValue: "task-email-approval")
        let runID = KanameID(rawValue: "run-email-approval")
        let sessionID = KanameID(rawValue: "session-email-approval")
        let approvalID = KanameID(rawValue: "approval-email-approval")
        let startedAt = Date(timeIntervalSince1970: 1_762_150_000)

        return Phase0Fixture(
            name: "waiting-for-email-approval",
            thread: KanameDomain.Thread(
                id: threadID,
                title: "Send the release-status draft",
                workspaceKind: .email
            ),
            task: Task(id: taskID, threadID: threadID, title: "Prepare release update"),
            providerSession: ProviderSession(id: sessionID, provider: "Fake Provider"),
            run: Run(id: runID, taskID: taskID, providerSessionID: sessionID),
            approvals: [
                Approval(
                    id: approvalID,
                    action: .sendEmail,
                    status: .pending,
                    target: "selected recipient list",
                    consequence: "send the reviewed status update outside Kaname",
                    expiresAt: startedAt.addingTimeInterval(1_800)
                ),
            ],
            queueItems: [],
            events: [
                event(1, .taskQueued, threadID, taskID, runID, startedAt),
                event(2, .runStarted, threadID, taskID, runID, startedAt),
                event(3, .approvalRequested, threadID, taskID, runID, startedAt, approvalID: approvalID),
            ]
        )
    }

    private static func makeRunningCodingTask() -> Phase0Fixture {
        let threadID = KanameID(rawValue: "thread-running-coding")
        let taskID = KanameID(rawValue: "task-running-coding")
        let runID = KanameID(rawValue: "run-running-coding")
        let sessionID = KanameID(rawValue: "session-running-coding")
        let startedAt = Date(timeIntervalSince1970: 1_762_175_000)

        return Phase0Fixture(
            name: "running-coding-task",
            thread: KanameDomain.Thread(
                id: threadID,
                title: "Map the repository knowledge boundary",
                workspaceKind: .coding
            ),
            task: Task(id: taskID, threadID: threadID, title: "Inspect project context safely"),
            providerSession: ProviderSession(
                id: sessionID,
                provider: "Fake Provider",
                nativeSessionID: "fixture-session-running-coding"
            ),
            run: Run(id: runID, taskID: taskID, providerSessionID: sessionID),
            approvals: [],
            queueItems: [],
            events: [
                event(1, .taskQueued, threadID, taskID, runID, startedAt),
                event(2, .runStarted, threadID, taskID, runID, startedAt),
                event(
                    3,
                    .nativeProviderEvent,
                    threadID,
                    taskID,
                    runID,
                    startedAt,
                    origin: EventOrigin(
                        kind: .provider,
                        provider: "Fake Provider",
                        nativeType: "search.progress",
                        rawPayload: Data("{\"filesScanned\":42}".utf8)
                    )
                ),
            ]
        )
    }

    private static func event(
        _ sequence: UInt64,
        _ kind: EventKind,
        _ threadID: KanameID,
        _ taskID: KanameID,
        _ runID: KanameID,
        _ startedAt: Date,
        approvalID: KanameID? = nil,
        origin: EventOrigin = EventOrigin(kind: .synthetic)
    ) -> EventEnvelope {
        EventEnvelope(
            id: KanameID(rawValue: "\(threadID.rawValue)-event-\(sequence)"),
            streamID: threadID,
            sequence: sequence,
            occurredAt: startedAt.addingTimeInterval(Double(sequence)),
            kind: kind,
            taskID: taskID,
            runID: runID,
            approvalID: approvalID,
            origin: origin
        )
    }
}
