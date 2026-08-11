import Testing
@testable import KanameDesktop

struct DesktopConversationNarrativeTests {
    @Test
    func toolBurstBecomesOneRunSummaryWhileCriticalEventsRemainVisible() throws {
        let run = providerRun(id: "run-1", sourceMessageID: "user-1", state: .completed)
        let events = (1...1_000).map { event(id: "tool-\($0)", kind: .tool, createdAt: Int64($0 + 10)) }
            + [event(id: "question-1", kind: .question, createdAt: 500)]

        let page = DesktopConversationNarrativePresentation.page(
            messages: [DesktopMessage(id: "user-1", role: .user, body: "Please investigate", createdAtUnixMillis: 1)],
            runs: [run],
            events: events
        )

        #expect(page.rows.count == 3)
        #expect(page.rows[0].id == "message-user-1")
        #expect(page.rows[1].id == "critical-question-1")
        guard case let .runSummary(summary) = page.rows[2] else {
            Issue.record("Expected a run summary")
            return
        }
        #expect(summary.activityCount == 1_001)
        #expect(summary.toolCount == 1_000)
        #expect(summary.criticalEvents.map(\.id) == ["question-1"])
    }

    @Test
    func transportEventsStayAvailableInActivityButOutOfNarrativeCounts() throws {
        let summary = try #require(DesktopConversationNarrativePresentation.runSummaries(
            runs: [providerRun(id: "run-1")],
            events: [
                event(id: "assistant-1", kind: .assistantText, createdAt: 10),
                event(id: "native-1", kind: .native, createdAt: 20),
                event(id: "status-1", kind: .status, createdAt: 30),
            ]
        ).first)

        #expect(summary.events.count == 3)
        #expect(summary.activityCount == 1)
        #expect(summary.conciseActivityLabel.contains("1 update"))
    }

    @Test
    func narrativePagesCompactRowsRatherThanRawProviderEvents() {
        let runs = (1...200).map { providerRun(id: "run-\($0)", startedAt: Int64($0 * 10)) }
        let events = runs.flatMap { run in
            (1...500).map { event(id: "\(run.id)-tool-\($0)", runID: run.id, kind: .tool, createdAt: run.startedAtUnixMillis + Int64($0)) }
        }

        let page = DesktopConversationNarrativePresentation.page(
            messages: [],
            runs: runs,
            events: events,
            maximumRows: 120
        )

        #expect(page.rows.count == 120)
        #expect(page.hiddenOlderRowCount == 80)
        #expect(page.rows.first?.id == "run-run-81")
        #expect(page.rows.last?.id == "run-run-200")
    }

    @Test
    func searchFindsConversationAndDeepActivityWithoutExpandingIt() {
        let page = DesktopConversationNarrativePresentation.page(
            messages: [
                DesktopMessage(id: "one", role: .user, body: "Unrelated request", createdAtUnixMillis: 1),
                DesktopMessage(id: "two", role: .assistant, body: "Finished the migration", createdAtUnixMillis: 2),
            ],
            runs: [providerRun(id: "run-1")],
            events: [event(id: "tool-1", kind: .tool, title: "Read file", detail: "RareNeedle.swift", createdAt: 3)],
            searchText: "RareNeedle"
        )

        #expect(page.rows.map(\.id) == ["run-run-1"])
    }

    private func providerRun(
        id: String,
        sourceMessageID: String? = nil,
        state: DesktopActionState = .running,
        startedAt: Int64 = 10
    ) -> DesktopProviderRunRecord {
        DesktopProviderRunRecord(
            id: id,
            threadID: "thread-1",
            sourceMessageID: sourceMessageID,
            provider: "Codex",
            model: "gpt-test",
            briefDigest: "digest",
            contextReferenceCount: 1,
            tokenUsage: state == .completed ? 42 : nil,
            costSummary: "Local",
            state: state,
            startedAtUnixMillis: startedAt,
            completedAtUnixMillis: state == .completed ? startedAt + 2_000 : nil
        )
    }

    private func event(
        id: String,
        runID: String = "run-1",
        kind: DesktopProviderEventKind,
        title: String = "Activity",
        detail: String = "Detail",
        createdAt: Int64
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
            payloadWasTruncated: false,
            createdAtUnixMillis: createdAt
        )
    }
}
