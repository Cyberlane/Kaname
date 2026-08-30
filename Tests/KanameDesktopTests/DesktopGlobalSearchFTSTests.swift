import Testing
@testable import KanameDesktop

struct DesktopGlobalSearchFTSTests {
    @Test
    func supplementalRowsIncludeThreadMessagesAndWorktreeDiffs() {
        var snapshot = DesktopAppSnapshot.starter(now: 1_000)
        snapshot.threads[0].messages.append(
            DesktopMessage(
                role: .assistant,
                body: "Implemented the checkpoint revert design for isolated worktrees.",
                createdAtUnixMillis: 2_000
            )
        )
        snapshot.operations.worktrees.append(
            DesktopWorktreeRecord(
                id: "worktree-1",
                projectID: "project-kaname",
                threadID: snapshot.threads[0].id,
                rootWorkspacePath: "/tmp/root",
                worktreePath: "/tmp/worktree",
                branch: "feature/checkpoints",
                baseRevision: "abc",
                headRevision: "def",
                changedFileCount: 2,
                diffSummary: "M Docs/CodingGitCheckpointsDesign.md",
                testCommand: "swift test",
                testSummary: "passed",
                diagnosticSummary: "",
                state: .dirty,
                createdAtUnixMillis: 1_500,
                updatedAtUnixMillis: 2_500
            )
        )

        let rows = DesktopGlobalSearchFTS.supplementalRows(from: snapshot)
        #expect(rows.contains { $0.documentID.hasPrefix("conversation-message:") })
        #expect(rows.contains { $0.documentID == "worktree-diff:worktree-1" })
    }

    @Test
    func ftsMatchingFindsMessageBodyTerms() {
        let rows = [indexedRow()]

        let result = DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: DesktopGlobalSearchQuery("checkpoint revert"),
            rows: rows
        )
        #expect(result == .matches(["conversation-message:t1:m1"]))
    }

    @Test
    func punctuationTokenDoesNotNullQuery() {
        let rows = [indexedRow()]

        #expect(DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: DesktopGlobalSearchQuery("checkpoint!!! revert"),
            rows: rows
        ) == .matches(["conversation-message:t1:m1"]))
        var databaseOpenCount = 0
        let punctuationOnly = DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: DesktopGlobalSearchQuery("!!! … 🔒"),
            rows: rows,
            limit: 50,
            databasePath: ":memory:",
            executionProbe: .init(didOpenDatabase: { databaseOpenCount += 1 })
        )
        #expect(punctuationOnly == .matches([]))
        #expect(databaseOpenCount == 0)
    }

    @Test
    func equalRankResultsStayStableAcrossRowPermutations() {
        let rows = [
            indexedRow(id: "zulu", body: "checkpoint recovery"),
            indexedRow(id: "alpha", body: "checkpoint recovery"),
            indexedRow(id: "middle", body: "checkpoint recovery"),
        ]
        let query = DesktopGlobalSearchQuery("checkpoint")

        let forward = DesktopGlobalSearchFTS.matchingDocumentIDs(query: query, rows: rows)
        let reversed = DesktopGlobalSearchFTS.matchingDocumentIDs(query: query, rows: Array(rows.reversed()))

        #expect(forward == .matches(["alpha", "middle", "zulu"]))
        #expect(reversed == forward)
    }

    @Test
    func cancellationStopsPopulationWithoutSurfacingFailure() {
        let rows = (0..<100).map { index in
            indexedRow(id: "row-\(index)", body: "checkpoint recovery \(index)")
        }
        var insertedRowCount = 0
        var databaseOpenCount = 0

        let result = DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: DesktopGlobalSearchQuery("checkpoint"),
            rows: rows,
            limit: 50,
            databasePath: ":memory:",
            executionProbe: .init(
                cancellationRequested: { insertedRowCount >= 2 },
                didOpenDatabase: { databaseOpenCount += 1 },
                didInsertRow: { insertedRowCount += 1 }
            )
        )

        #expect(result == .cancelled)
        #expect(result.failure == nil)
        #expect(databaseOpenCount == 1)
        #expect(insertedRowCount == 2)
    }

    @Test
    func unicode61CJKAndCombiningQueriesMatchSQLiteTokenizer() {
        let rows = [
            indexedRow(id: "cjk", body: "復旧 手順"),
            indexedRow(id: "accent", body: "café review"),
        ]

        #expect(DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: DesktopGlobalSearchQuery("復旧"),
            rows: rows
        ) == .matches(["cjk"]))
        #expect(DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: DesktopGlobalSearchQuery("cafe\u{301}"),
            rows: rows
        ) == .matches(["accent"]))
    }

    @Test
    func typedFailureDiffersFromNoMatchesAndBoundsItsReason() throws {
        let rows = [indexedRow()]
        let noMatches = DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: DesktopGlobalSearchQuery("missing"),
            rows: rows
        )
        let failure = DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: DesktopGlobalSearchQuery("checkpoint"),
            rows: rows,
            limit: 50,
            databasePath: "/dev/null/kaname-search.sqlite"
        )

        #expect(noMatches == .matches([]))
        let detail = try #require(failure.failure)
        #expect(detail.stage == .databaseOpen)
        #expect(!detail.reason.isEmpty)
        #expect(detail.reason.utf8.count <= DesktopGlobalSearchFTS.maximumFailureReasonBytes)
        #expect(!detail.reason.contains("\n"))
        #expect(failure != noMatches)

        let bounded = DesktopGlobalSearchFTS.Failure(
            stage: .queryExecution,
            reason: String(repeating: "failure ", count: 100) + "\nprivate detail"
        )
        #expect(bounded.reason.utf8.count <= DesktopGlobalSearchFTS.maximumFailureReasonBytes)
        #expect(!bounded.reason.contains("\n"))
    }

    @Test
    func snapshotGenerationUsesEligibleIdentityTimestampsAndBoundedContent() throws {
        var snapshot = DesktopAppSnapshot.starter(now: 1_000)
        snapshot.operations.worktrees = []
        snapshot.threads = [snapshot.threads[0]]
        snapshot.threads[0].messages = [
            DesktopMessage(
                id: "blank",
                role: .system,
                body: "  \n ",
                createdAtUnixMillis: 1_500
            ),
            DesktopMessage(
                id: "eligible",
                role: .assistant,
                body: "checkpoint evidence",
                createdAtUnixMillis: 2_000
            ),
        ]
        snapshot.threads[0].updatedAtUnixMillis = 2_500

        let first = DesktopGlobalSearchFTS.snapshotGeneration(from: snapshot)
        let firstIdentity = try #require(first.indexedIdentities.first)
        #expect(first.indexedIdentities.count == 1)
        #expect(firstIdentity.documentID == "conversation-message:\(snapshot.threads[0].id):eligible")
        #expect(firstIdentity.updatedAtUnixMillis == 2_500)
        #expect(firstIdentity.contentFingerprint.utf8.count == 64)

        snapshot.lastSavedAtUnixMillis += 1
        #expect(DesktopGlobalSearchFTS.snapshotGeneration(from: snapshot) == first)

        snapshot.threads[0].updatedAtUnixMillis = 3_000
        let updated = DesktopGlobalSearchFTS.snapshotGeneration(from: snapshot)
        #expect(updated != first)
        #expect(try #require(updated.indexedIdentities.first).updatedAtUnixMillis == 3_000)
    }

    @Test
    func streamingAssistantDeltaInvalidatesRowsBeforeTimestampChanges() async {
        var snapshot = DesktopAppSnapshot.starter(now: 1_000)
        snapshot.operations.worktrees = []
        snapshot.threads = [snapshot.threads[0]]
        snapshot.threads[0].messages = [
            DesktopMessage(
                id: "streaming",
                role: .assistant,
                body: "Drafting the response",
                createdAtUnixMillis: 2_000
            ),
        ]
        snapshot.threads[0].updatedAtUnixMillis = 2_000
        let cache = DesktopGlobalSearchFTS.IndexedRowCache()

        let initialRows = await cache.rows(for: snapshot)
        let initialGeneration = DesktopGlobalSearchFTS.snapshotGeneration(from: snapshot)
        #expect(DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: DesktopGlobalSearchQuery("rollback"),
            rows: initialRows
        ) == .matches([]))

        snapshot.threads[0].messages[0] = DesktopMessage(
            id: "streaming",
            role: .assistant,
            body: "Drafting the response with rollback evidence",
            createdAtUnixMillis: 2_000
        )
        let updatedRows = await cache.rows(for: snapshot)
        let updatedGeneration = DesktopGlobalSearchFTS.snapshotGeneration(from: snapshot)
        let statistics = await cache.statistics()

        #expect(snapshot.threads[0].messages[0].createdAtUnixMillis == 2_000)
        #expect(snapshot.threads[0].updatedAtUnixMillis == 2_000)
        #expect(updatedGeneration != initialGeneration)
        #expect(statistics.rowsBuildCount == 2)
        #expect(DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: DesktopGlobalSearchQuery("rollback"),
            rows: updatedRows
        ) == .matches(["conversation-message:\(snapshot.threads[0].id):streaming"]))
    }

    private func indexedRow(
        id: String = "conversation-message:t1:m1",
        body: String = "checkpoint revert restores the worktree before review"
    ) -> DesktopGlobalSearchFTS.IndexedRow {
        DesktopGlobalSearchFTS.IndexedRow(
            documentID: id,
            domain: .conversations,
            title: "Coding · Assistant",
            body: body,
            keywords: ["assistant"],
            target: .init(kind: .conversation, itemID: "t1"),
            threadID: "t1",
            projectID: nil,
            updatedAtUnixMillis: 1
        )
    }
}
