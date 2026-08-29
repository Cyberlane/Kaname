import Foundation
import KanameDomain
import SQLite3

/// Full-text indexing for thread messages and worktree diffs in Command Center search.
public enum DesktopGlobalSearchFTS {
    public static let maximumMessageBodyBytes = 4_096
    public static let maximumDiffSummaryBytes = 2_048
    public static let maximumIndexedMessagesPerThread = 64

    public struct IndexedRow: Equatable, Sendable {
        public let documentID: String
        public let domain: DesktopGlobalSearchDomain
        public let title: String
        public let body: String
        public let keywords: [String]
        public let target: DesktopGlobalSearchNavigationTarget
        public let threadID: String?
        public let projectID: String?
        public let updatedAtUnixMillis: Int64
    }

    public static func supplementalRows(from snapshot: DesktopAppSnapshot) -> [IndexedRow] {
        let projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0.name) })
        var rows: [IndexedRow] = []

        for thread in snapshot.threads {
            let recentMessages = thread.messages.suffix(maximumIndexedMessagesPerThread)
            for message in recentMessages {
                let boundedBody = KanameTextBounds.utf8Prefix(
                    message.body.trimmingCharacters(in: .whitespacesAndNewlines),
                    maximumBytes: maximumMessageBodyBytes
                )
                guard !boundedBody.isEmpty else { continue }
                rows.append(
                    IndexedRow(
                        documentID: "conversation-message:\(thread.id):\(message.id)",
                        domain: .conversations,
                        title: "\(thread.title) · \(message.role.label)",
                        body: boundedBody,
                        keywords: [message.role.rawValue, thread.provider, thread.model],
                        target: .init(kind: .conversation, itemID: thread.id, scopeID: thread.projectID),
                        threadID: thread.id,
                        projectID: thread.projectID,
                        updatedAtUnixMillis: message.createdAtUnixMillis
                    )
                )
            }
        }

        for worktree in snapshot.operations.worktrees {
            let summary = KanameTextBounds.utf8Prefix(
                worktree.diffSummary.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumBytes: maximumDiffSummaryBytes
            )
            let detail = [
                worktree.branch,
                worktree.testSummary,
                worktree.diagnosticSummary,
                summary,
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            guard !detail.isEmpty else { continue }
            rows.append(
                IndexedRow(
                    documentID: "worktree-diff:\(worktree.id)",
                    domain: .github,
                    title: "Worktree · \(worktree.branch)",
                    body: detail,
                    keywords: [worktree.state.label, worktree.branch, "\(worktree.changedFileCount) files"],
                    target: .init(kind: .githubWork, itemID: worktree.id, scopeID: worktree.projectID),
                    threadID: worktree.threadID,
                    projectID: worktree.projectID,
                    updatedAtUnixMillis: worktree.updatedAtUnixMillis
                )
            )
        }

        _ = projects
        return rows
    }

    public static func supplementalDocuments(
        from snapshot: DesktopAppSnapshot,
        capturedAtUnixMillis: Int64
    ) -> [DesktopGlobalSearchDocument] {
        let projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0.name) })
        return supplementalRows(from: snapshot).map { row in
            DesktopGlobalSearchDocument.localSnapshot(
                identity: DesktopGlobalSearchIdentity(
                    id: row.documentID,
                    domain: row.domain,
                    navigationTarget: row.target
                ),
                content: DesktopGlobalSearchContent(
                    title: row.title,
                    summary: row.body,
                    keywords: row.keywords
                ),
                provenance: DesktopGlobalSearchProvenance.localSnapshot(
                    source: .kanameWorkspace,
                    sourceID: row.threadID ?? row.documentID,
                    sourceLabel: row.documentID.hasPrefix("worktree-diff:")
                        ? "Git worktree diff snapshot"
                        : "Conversation message snapshot",
                    projectID: row.projectID,
                    projectLabel: row.projectID.flatMap { projects[$0] },
                    capturedAtUnixMillis: capturedAtUnixMillis
                ),
                updatedAtUnixMillis: row.updatedAtUnixMillis
            )
        }
    }

    public static func matchingDocumentIDs(
        query: DesktopGlobalSearchQuery,
        rows: [IndexedRow],
        limit: Int = 50
    ) -> [String] {
        guard !query.isEmpty, !rows.isEmpty, limit > 0 else { return [] }
        guard let database = openMemoryDatabase() else { return [] }
        defer { sqlite3_close(database) }

        guard createSchema(on: database) else { return [] }
        guard insert(rows: rows, into: database) else { return [] }

        let match = rowsQuery(from: query)
        guard !match.isEmpty else { return [] }

        var statement: OpaquePointer?
        let sql = """
        SELECT document_id FROM search_index
        WHERE search_index MATCH ?
        ORDER BY bm25(search_index)
        LIMIT ?
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, match, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            ids.append(String(cString: cString))
        }
        return ids
    }

    private static func rowsQuery(from query: DesktopGlobalSearchQuery) -> String {
        query.tokens
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " AND ")
    }

    private static func openMemoryDatabase() -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open(":memory:", &database) == SQLITE_OK else { return nil }
        return database
    }

    private static func createSchema(on database: OpaquePointer?) -> Bool {
        let sql = """
        CREATE VIRTUAL TABLE search_index USING fts5(
            document_id UNINDEXED,
            title,
            body,
            keywords,
            tokenize='unicode61'
        );
        """
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func insert(rows: [IndexedRow], into database: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        let sql = "INSERT INTO search_index(document_id, title, body, keywords) VALUES (?, ?, ?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, row.documentID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, row.title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 3, row.body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(
                statement,
                4,
                row.keywords.joined(separator: " "),
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
            guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        }
        return true
    }
}

private extension DesktopMessageRole {
    var label: String {
        switch self {
        case .user: "User"
        case .assistant: "Assistant"
        case .system: "System"
        }
    }
}
