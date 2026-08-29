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
        let rows = [
            DesktopGlobalSearchFTS.IndexedRow(
                documentID: "conversation-message:t1:m1",
                domain: .conversations,
                title: "Coding · Assistant",
                body: "checkpoint revert restores the worktree before review",
                keywords: ["assistant"],
                target: .init(kind: .conversation, itemID: "t1"),
                threadID: "t1",
                projectID: nil,
                updatedAtUnixMillis: 1
            ),
        ]

        let ids = DesktopGlobalSearchFTS.matchingDocumentIDs(
            query: DesktopGlobalSearchQuery("checkpoint revert"),
            rows: rows
        )
        #expect(ids == ["conversation-message:t1:m1"])
    }
}
