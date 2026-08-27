import Testing
@testable import KanameDesktop
import KanameDomain

struct DesktopConversationTimelineTests {
    @Test
    func twoMatchingEventsCollapseWithLatestSummaryAndTruncationWarning() throws {
        let first = event(
            id: "tool-1",
            kind: .tool,
            title: "Read file",
            detail: "Sources/First.swift",
            createdAt: 10,
            payloadWasTruncated: true
        )
        let second = event(
            id: "tool-2",
            kind: .tool,
            title: "Search code",
            detail: "Found timeline symbols",
            createdAt: 20
        )

        let rows = DesktopConversationTimelinePresentation.rows(messages: [], providerEvents: [first, second])
        let group = try #require(eventGroup(in: rows))

        #expect(rows.count == 1)
        #expect(group.id == "event-group-thread-1-tool-1")
        #expect(group.events.map(\.id) == ["tool-1", "tool-2"])
        #expect(group.summaryTitle == "2 tool activities")
        #expect(group.latestSummary == "Search code · Found timeline symbols")
        #expect(group.latestCreatedAtUnixMillis == 20)
        #expect(group.containsTruncatedPayload)
        #expect(group.accessibilityLabel(isExpanded: false).contains("Collapsed"))
        #expect(group.accessibilityLabel(isExpanded: false).contains("Latest: Search code"))
        #expect(group.accessibilityLabel(isExpanded: false).contains("exceeded the evidence limit"))
        #expect(group.accessibilityLabel(isExpanded: true).contains("Expanded"))
    }

    @Test
    func maximalMatchingRunPreservesChronologicalExpansionOrder() throws {
        let newest = event(id: "tool-3", kind: .tool, createdAt: 30)
        let oldest = event(id: "tool-1", kind: .tool, createdAt: 10)
        let middle = event(id: "tool-2", kind: .tool, createdAt: 20)

        let rows = DesktopConversationTimelinePresentation.rows(
            messages: [],
            providerEvents: [newest, oldest, middle]
        )
        let group = try #require(eventGroup(in: rows))

        #expect(group.events.map(\.id) == ["tool-1", "tool-2", "tool-3"])
        #expect(group.count == 3)
    }

    @Test
    func oneStructuredToolLifecycleGroupsAsOneLogicalToolCall() throws {
        var started = event(id: "tool-started", kind: .tool, createdAt: 10)
        started.toolObservation = ProviderToolObservation(
            callID: "call-1",
            kind: .commandExecution,
            state: .running,
            name: "Command"
        )
        var completed = event(id: "tool-completed", kind: .tool, createdAt: 20)
        completed.toolObservation = ProviderToolObservation(
            callID: "call-1",
            kind: .commandExecution,
            state: .completed,
            name: "Command"
        )

        let rows = DesktopConversationTimelinePresentation.rows(
            messages: [],
            providerEvents: [started, completed]
        )
        let group = try #require(eventGroup(in: rows))

        #expect(group.events.count == 2)
        #expect(group.count == 1)
        #expect(group.summaryTitle == "1 tool activity")
    }

    @Test
    func oneAgentLifecycleGroupsAsOneLogicalAgent() throws {
        var started = event(id: "agent-started", kind: .tool, createdAt: 10)
        started.agentActivity = ProviderAgentActivity(agentID: "agent-1", activity: .started)
        var completed = event(id: "agent-completed", kind: .tool, createdAt: 20)
        completed.agentActivity = ProviderAgentActivity(agentID: "agent-1", activity: .completed)

        let rows = DesktopConversationTimelinePresentation.rows(
            messages: [],
            providerEvents: [started, completed]
        )
        let group = try #require(eventGroup(in: rows))

        #expect(group.count == 1)
        #expect(group.summaryTitle == "1 agent activity")
    }

    @Test
    func singletonRemainsAnOrdinaryEventAndHiddenTransportEventsStayOutOfTimeline() {
        let visible = event(id: "status-1", kind: .status, createdAt: 10)
        let assistantText = event(id: "text-1", kind: .assistantText, createdAt: 20)
        let native = event(id: "native-1", kind: .native, createdAt: 30)

        let rows = DesktopConversationTimelinePresentation.rows(
            messages: [],
            providerEvents: [visible, assistantText, native]
        )

        #expect(rows.count == 1)
        guard case let .event(event) = rows[0] else {
            Issue.record("Expected a standalone visible event")
            return
        }
        #expect(event.id == visible.id)
    }

    @Test
    func messagesKindsAndRunsTerminateGroups() {
        let message = DesktopMessage(id: "message-1", role: .user, body: "Continue", createdAtUnixMillis: 25)
        let rows = DesktopConversationTimelinePresentation.rows(from: [
            .event(event(id: "tool-1", runID: "run-1", kind: .tool, createdAt: 10)),
            .event(event(id: "tool-2", runID: "run-1", kind: .tool, createdAt: 20)),
            .message(message),
            .event(event(id: "tool-3", runID: "run-1", kind: .tool, createdAt: 30)),
            .event(event(id: "reasoning-1", runID: "run-1", kind: .reasoning, createdAt: 40)),
            .event(event(id: "reasoning-2", runID: "run-2", kind: .reasoning, createdAt: 50)),
        ])

        #expect(rows.count == 5)
        guard case let .eventGroup(firstGroup) = rows[0] else {
            Issue.record("Expected the first matching tool run to group")
            return
        }
        #expect(firstGroup.events.map(\.id) == ["tool-1", "tool-2"])
        #expect(rows[1].id == "message-message-1")
        #expect(rows[2].id == "event-tool-3")
        #expect(rows[3].id == "event-reasoning-1")
        #expect(rows[4].id == "event-reasoning-2")
    }

    @Test
    func questionsApprovalsAndErrorsAlwaysRemainFirstClassRows() {
        let events = [
            event(id: "question-1", kind: .question, createdAt: 10),
            event(id: "question-2", kind: .question, createdAt: 20),
            event(id: "approval-1", kind: .approval, createdAt: 30),
            event(id: "approval-2", kind: .approval, createdAt: 40),
            event(id: "error-1", kind: .error, createdAt: 50),
            event(id: "error-2", kind: .error, createdAt: 60),
        ]

        let rows = DesktopConversationTimelinePresentation.rows(messages: [], providerEvents: events)

        #expect(rows.count == events.count)
        #expect(rows.map(\.id) == events.map { "event-\($0.id)" })
        #expect(rows.allSatisfy {
            if case .event = $0 { return true }
            return false
        })
    }

    @Test
    func appendingToAStreamingGroupKeepsItsStableIdentity() throws {
        let first = event(id: "status-1", kind: .status, createdAt: 10)
        let second = event(id: "status-2", kind: .status, createdAt: 20)
        let third = event(id: "status-3", kind: .status, createdAt: 30)

        let initialRows = DesktopConversationTimelinePresentation.rows(
            messages: [],
            providerEvents: [first, second]
        )
        let updatedRows = DesktopConversationTimelinePresentation.rows(
            messages: [],
            providerEvents: [first, second, third]
        )
        let initialGroup = try #require(eventGroup(in: initialRows))
        let updatedGroup = try #require(eventGroup(in: updatedRows))

        #expect(initialGroup.id == updatedGroup.id)
        #expect(updatedGroup.events.map(\.id) == ["status-1", "status-2", "status-3"])
        #expect(updatedGroup.summaryTitle == "3 status updates")
    }

    @Test
    func largeHistoryRendersOnlyTheNewestBoundedPage() {
        let events = (1...1_000).map {
            event(id: "error-\($0)", kind: .error, createdAt: Int64($0))
        }

        let page = DesktopConversationTimelinePresentation.page(
            messages: [],
            providerEvents: events,
            maximumEntries: 400
        )

        #expect(page.hiddenOlderEntryCount == 600)
        #expect(page.rows.count == 400)
        #expect(page.rows.first?.id == "event-error-601")
        #expect(page.rows.last?.id == "event-error-1000")
    }

    @Test
    func loadingAnOlderPageRetainsChronologicalOrderAndGrouping() throws {
        let events = (1...500).map {
            event(id: "tool-\($0)", kind: .tool, createdAt: Int64($0))
        }
        let page = DesktopConversationTimelinePresentation.page(
            messages: [],
            providerEvents: events,
            maximumEntries: 400
        )
        let group = try #require(eventGroup(in: page.rows))

        #expect(page.hiddenOlderEntryCount == 100)
        #expect(group.events.first?.id == "tool-101")
        #expect(group.events.last?.id == "tool-500")
    }

    private func eventGroup(
        in rows: [DesktopConversationTimelineRow]
    ) -> DesktopProviderEventGroup? {
        guard rows.count == 1, case let .eventGroup(group) = rows[0] else { return nil }
        return group
    }

    private func event(
        id: String,
        runID: String = "run-1",
        kind: DesktopProviderEventKind,
        title: String = "Activity",
        detail: String = "Detail",
        createdAt: Int64,
        payloadWasTruncated: Bool = false
    ) -> DesktopProviderEventRecord {
        DesktopProviderEventRecord(
            id: id,
            threadID: "thread-1",
            runID: runID,
            kind: kind,
            title: title,
            detail: detail,
            nativeType: "test/event",
            nativeThreadID: "native-thread",
            nativeTurnID: "native-turn",
            approvalID: nil,
            rawPayloadBase64: nil,
            payloadWasTruncated: payloadWasTruncated,
            createdAtUnixMillis: createdAt
        )
    }
}
