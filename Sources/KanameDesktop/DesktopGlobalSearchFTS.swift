import CryptoKit
import Foundation
import KanameDomain
import SQLite3

private final class DesktopGlobalSearchSQLiteCancellationContext {
    let cancellationRequested: () -> Bool

    init(cancellationRequested: @escaping () -> Bool) {
        self.cancellationRequested = cancellationRequested
    }
}

private let desktopGlobalSearchSQLiteProgressHandler: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
    context in
    guard let context else { return 0 }
    let cancellation = Unmanaged<DesktopGlobalSearchSQLiteCancellationContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    return cancellation.cancellationRequested() ? 1 : 0
}

/// Full-text indexing for thread messages and worktree diffs in Command Center search.
public enum DesktopGlobalSearchFTS {
    public static let maximumMessageBodyBytes = 4_096
    public static let maximumDiffSummaryBytes = 2_048
    public static let maximumIndexedMessagesPerThread = 64
    public static let maximumMatchCount = 200
    public static let maximumFailureReasonBytes = 160

    public struct SnapshotGeneration: Equatable, Sendable {
        public struct IndexedIdentity: Equatable, Sendable {
            public let documentID: String
            public let updatedAtUnixMillis: Int64
            public let contentFingerprint: String

            public init(
                documentID: String,
                updatedAtUnixMillis: Int64,
                contentFingerprint: String
            ) {
                self.documentID = documentID
                self.updatedAtUnixMillis = updatedAtUnixMillis
                self.contentFingerprint = contentFingerprint
            }
        }

        public let indexedIdentities: [IndexedIdentity]

        public init(indexedIdentities: [IndexedIdentity]) {
            self.indexedIdentities = indexedIdentities
        }
    }

    public struct CacheStatistics: Equatable, Sendable {
        public let generation: SnapshotGeneration?
        public let rowsBuildCount: Int
        public let cachedRowCount: Int
    }

    /// A one-generation cache. Actor isolation coalesces concurrent keystrokes so
    /// eligible message and worktree rows are built at most once per generation.
    public actor IndexedRowCache {
        private var cachedGeneration: SnapshotGeneration?
        private var cachedRows: [IndexedRow] = []
        private var rowsBuildCount = 0

        public init() {}

        public func rows(for snapshot: DesktopAppSnapshot) -> [IndexedRow] {
            let generation = DesktopGlobalSearchFTS.snapshotGeneration(from: snapshot)
            if cachedGeneration == generation {
                return cachedRows
            }

            let rows = DesktopGlobalSearchFTS.supplementalRows(from: snapshot)
            cachedGeneration = generation
            cachedRows = rows
            rowsBuildCount += 1
            return rows
        }

        public func statistics() -> CacheStatistics {
            CacheStatistics(
                generation: cachedGeneration,
                rowsBuildCount: rowsBuildCount,
                cachedRowCount: cachedRows.count
            )
        }
    }

    public struct Failure: Error, Equatable, Sendable {
        public enum Stage: String, Equatable, Sendable {
            case databaseOpen
            case schemaCreation
            case rowInsertion
            case queryPreparation
            case queryBinding
            case queryExecution
        }

        public let stage: Stage
        public let reason: String

        public init(stage: Stage, reason: String) {
            self.stage = stage
            let singleLine = reason
                .split(whereSeparator: \Character.isNewline)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bounded = KanameTextBounds.utf8Prefix(
                singleLine,
                maximumBytes: DesktopGlobalSearchFTS.maximumFailureReasonBytes
            )
            self.reason = bounded.isEmpty ? "SQLite full-text search failed." : bounded
        }

        public var statusLine: String {
            "Full-text ranking unavailable: \(reason)"
        }
    }

    public enum MatchResult: Equatable, Sendable {
        case matches([String])
        case failure(Failure)
        case cancelled

        public var documentIDs: [String] {
            switch self {
            case let .matches(documentIDs): documentIDs
            case .failure, .cancelled: []
            }
        }

        public var failure: Failure? {
            guard case let .failure(failure) = self else { return nil }
            return failure
        }
    }

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

    struct ExecutionProbe {
        let cancellationRequested: () -> Bool
        let didOpenDatabase: () -> Void
        let didInsertRow: () -> Void

        init(
            cancellationRequested: @escaping () -> Bool = {
                _Concurrency.Task<Never, Never>.isCancelled
            },
            didOpenDatabase: @escaping () -> Void = {},
            didInsertRow: @escaping () -> Void = {}
        ) {
            self.cancellationRequested = cancellationRequested
            self.didOpenDatabase = didOpenDatabase
            self.didInsertRow = didInsertRow
        }
    }

    public static func snapshotGeneration(from snapshot: DesktopAppSnapshot) -> SnapshotGeneration {
        var identities: [SnapshotGeneration.IndexedIdentity] = []

        for thread in snapshot.threads {
            for message in thread.messages.suffix(maximumIndexedMessagesPerThread)
            where containsNonWhitespace(message.body) {
                guard let boundedBody = boundedMessageBody(message.body) else { continue }
                let documentID = "conversation-message:\(thread.id):\(message.id)"
                let updatedAtUnixMillis = max(
                    message.createdAtUnixMillis,
                    thread.updatedAtUnixMillis
                )
                identities.append(
                    SnapshotGeneration.IndexedIdentity(
                        documentID: documentID,
                        updatedAtUnixMillis: updatedAtUnixMillis,
                        contentFingerprint: contentFingerprint(components: [
                            documentID,
                            DesktopGlobalSearchDomain.conversations.rawValue,
                            "\(thread.title) · \(message.role.label)",
                            boundedBody,
                            message.role.rawValue,
                            thread.provider,
                            thread.model,
                            DesktopGlobalSearchNavigationTarget.Kind.conversation.rawValue,
                            thread.id,
                            thread.projectID,
                            thread.id,
                            thread.projectID,
                            String(message.createdAtUnixMillis),
                        ])
                    )
                )
            }
        }

        for worktree in snapshot.operations.worktrees where hasEligibleDetail(worktree) {
            guard let detail = worktreeDetail(worktree) else { continue }
            let documentID = "worktree-diff:\(worktree.id)"
            identities.append(
                SnapshotGeneration.IndexedIdentity(
                    documentID: documentID,
                    updatedAtUnixMillis: worktree.updatedAtUnixMillis,
                    contentFingerprint: contentFingerprint(components: [
                        documentID,
                        DesktopGlobalSearchDomain.github.rawValue,
                        "Worktree · \(worktree.branch)",
                        detail,
                        worktree.state.label,
                        worktree.branch,
                        "\(worktree.changedFileCount) files",
                        DesktopGlobalSearchNavigationTarget.Kind.githubWork.rawValue,
                        worktree.id,
                        worktree.projectID,
                        worktree.threadID,
                        worktree.projectID,
                        String(worktree.updatedAtUnixMillis),
                    ])
                )
            )
        }

        identities.sort {
            if $0.documentID != $1.documentID { return $0.documentID < $1.documentID }
            return $0.updatedAtUnixMillis < $1.updatedAtUnixMillis
        }
        return SnapshotGeneration(indexedIdentities: identities)
    }

    public static func supplementalRows(from snapshot: DesktopAppSnapshot) -> [IndexedRow] {
        var rows: [IndexedRow] = []

        for thread in snapshot.threads {
            let recentMessages = thread.messages.suffix(maximumIndexedMessagesPerThread)
            for message in recentMessages {
                guard let boundedBody = boundedMessageBody(message.body) else { continue }
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
            guard let detail = worktreeDetail(worktree) else { continue }
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

        return rows
    }

    public static func supplementalDocuments(
        from snapshot: DesktopAppSnapshot,
        capturedAtUnixMillis: Int64
    ) -> [DesktopGlobalSearchDocument] {
        let projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0.name) })
        return supplementalDocuments(
            from: supplementalRows(from: snapshot),
            projectNamesByID: projects,
            capturedAtUnixMillis: capturedAtUnixMillis
        )
    }

    static func supplementalDocuments(
        from rows: [IndexedRow],
        projectNamesByID projects: [String: String],
        capturedAtUnixMillis: Int64
    ) -> [DesktopGlobalSearchDocument] {
        rows.map { row in
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
    ) -> MatchResult {
        matchingDocumentIDs(query: query, rows: rows, limit: limit, databasePath: ":memory:")
    }

    static func matchingDocumentIDs(
        query: DesktopGlobalSearchQuery,
        rows: [IndexedRow],
        limit: Int,
        databasePath: String,
        executionProbe: ExecutionProbe = ExecutionProbe()
    ) -> MatchResult {
        guard !query.isEmpty, !rows.isEmpty, limit > 0 else { return .matches([]) }
        let match = rowsQuery(from: query)
        guard !match.isEmpty else { return .matches([]) }
        guard !executionProbe.cancellationRequested() else { return .cancelled }

        var database: OpaquePointer?
        executionProbe.didOpenDatabase()
        let openCode = sqlite3_open(databasePath, &database)
        guard openCode == SQLITE_OK, let database else {
            if executionProbe.cancellationRequested() {
                if let database { sqlite3_interrupt(database) }
                if let database { sqlite3_close(database) }
                return .cancelled
            }
            let failure = sqliteFailure(
                stage: .databaseOpen,
                database: database,
                code: openCode,
                fallback: "Could not open the in-memory search database."
            )
            if let database { sqlite3_close(database) }
            return .failure(failure)
        }
        let cancellationContext = DesktopGlobalSearchSQLiteCancellationContext(
            cancellationRequested: executionProbe.cancellationRequested
        )
        sqlite3_progress_handler(
            database,
            100,
            desktopGlobalSearchSQLiteProgressHandler,
            Unmanaged.passUnretained(cancellationContext).toOpaque()
        )
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            sqlite3_close(database)
        }

        let schemaCode = createSchema(on: database)
        guard schemaCode == SQLITE_OK else {
            if cancellationDetected(
                code: schemaCode,
                database: database,
                executionProbe: executionProbe
            ) {
                return .cancelled
            }
            return .failure(sqliteFailure(
                stage: .schemaCreation,
                database: database,
                code: schemaCode,
                fallback: "Could not create the full-text search schema."
            ))
        }
        switch insert(rows: rows, into: database, executionProbe: executionProbe) {
        case .success: break
        case .cancelled: return .cancelled
        case let .failure(failure): return .failure(failure)
        }
        guard !executionProbe.cancellationRequested() else {
            sqlite3_interrupt(database)
            return .cancelled
        }

        var statement: OpaquePointer?
        let sql = """
        SELECT document_id FROM search_index
        WHERE search_index MATCH ?
        ORDER BY bm25(search_index), document_id
        LIMIT ?
        """
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK else {
            if cancellationDetected(
                code: prepareCode,
                database: database,
                executionProbe: executionProbe
            ) {
                return .cancelled
            }
            return .failure(sqliteFailure(
                stage: .queryPreparation,
                database: database,
                code: prepareCode,
                fallback: "Could not prepare the full-text search query."
            ))
        }
        defer { sqlite3_finalize(statement) }

        let matchBindCode = sqlite3_bind_text(
            statement,
            1,
            match,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
        guard matchBindCode == SQLITE_OK else {
            if cancellationDetected(
                code: matchBindCode,
                database: database,
                executionProbe: executionProbe
            ) {
                return .cancelled
            }
            return .failure(sqliteFailure(
                stage: .queryBinding,
                database: database,
                code: matchBindCode,
                fallback: "Could not bind the full-text search query."
            ))
        }
        let boundedLimit = min(limit, maximumMatchCount)
        let limitBindCode = sqlite3_bind_int64(statement, 2, sqlite3_int64(boundedLimit))
        guard limitBindCode == SQLITE_OK else {
            if cancellationDetected(
                code: limitBindCode,
                database: database,
                executionProbe: executionProbe
            ) {
                return .cancelled
            }
            return .failure(sqliteFailure(
                stage: .queryBinding,
                database: database,
                code: limitBindCode,
                fallback: "Could not bind the full-text search result limit."
            ))
        }

        var ids: [String] = []
        ids.reserveCapacity(boundedLimit)
        while true {
            if executionProbe.cancellationRequested() {
                sqlite3_interrupt(database)
                return .cancelled
            }
            let stepCode = sqlite3_step(statement)
            switch stepCode {
            case SQLITE_ROW:
                guard let cString = sqlite3_column_text(statement, 0) else { continue }
                ids.append(String(cString: cString))
            case SQLITE_DONE:
                return .matches(ids)
            default:
                if cancellationDetected(
                    code: stepCode,
                    database: database,
                    executionProbe: executionProbe
                ) {
                    return .cancelled
                }
                return .failure(sqliteFailure(
                    stage: .queryExecution,
                    database: database,
                    code: stepCode,
                    fallback: "The full-text search query failed."
                ))
            }
        }
    }

    private static func rowsQuery(from query: DesktopGlobalSearchQuery) -> String {
        query.indexableTokens
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " AND ")
    }

    static func unicode61Tokens(in value: String) -> [String] {
        var tokens: [String] = []
        var token = ""

        func finishToken() {
            guard !token.isEmpty else { return }
            tokens.append(token)
            token.removeAll(keepingCapacity: true)
        }

        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar.properties.generalCategory == .privateUse {
                token.unicodeScalars.append(scalar)
            } else {
                finishToken()
            }
        }
        finishToken()
        return tokens
    }

    private static func createSchema(on database: OpaquePointer?) -> Int32 {
        let sql = """
        CREATE VIRTUAL TABLE search_index USING fts5(
            document_id UNINDEXED,
            title,
            body,
            keywords,
            tokenize='unicode61'
        );
        """
        return sqlite3_exec(database, sql, nil, nil, nil)
    }

    private enum PopulationResult {
        case success
        case cancelled
        case failure(Failure)
    }

    private static func insert(
        rows: [IndexedRow],
        into database: OpaquePointer?,
        executionProbe: ExecutionProbe
    ) -> PopulationResult {
        let beginCode = sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
        guard beginCode == SQLITE_OK else {
            if cancellationDetected(
                code: beginCode,
                database: database,
                executionProbe: executionProbe
            ) {
                return .cancelled
            }
            return .failure(sqliteFailure(
                stage: .rowInsertion,
                database: database,
                code: beginCode,
                fallback: "Could not start the full-text index transaction."
            ))
        }
        var transactionCommitted = false
        defer {
            if !transactionCommitted {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            }
        }

        var statement: OpaquePointer?
        let sql = "INSERT INTO search_index(document_id, title, body, keywords) VALUES (?, ?, ?, ?)"
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK else {
            if cancellationDetected(
                code: prepareCode,
                database: database,
                executionProbe: executionProbe
            ) {
                return .cancelled
            }
            return .failure(sqliteFailure(
                stage: .rowInsertion,
                database: database,
                code: prepareCode,
                fallback: "Could not prepare the full-text index writer."
            ))
        }
        defer { sqlite3_finalize(statement) }

        for row in rows {
            if executionProbe.cancellationRequested() {
                if let database { sqlite3_interrupt(database) }
                return .cancelled
            }
            let resetCode = sqlite3_reset(statement)
            let clearCode = sqlite3_clear_bindings(statement)
            guard resetCode == SQLITE_OK, clearCode == SQLITE_OK else {
                let code = resetCode == SQLITE_OK ? clearCode : resetCode
                if cancellationDetected(
                    code: code,
                    database: database,
                    executionProbe: executionProbe
                ) {
                    return .cancelled
                }
                return .failure(sqliteFailure(
                    stage: .rowInsertion,
                    database: database,
                    code: code,
                    fallback: "Could not reset the full-text index writer."
                ))
            }
            let values = [row.documentID, row.title, row.body, row.keywords.joined(separator: " ")]
            for (offset, value) in values.enumerated() {
                let bindCode = sqlite3_bind_text(
                    statement,
                    Int32(offset + 1),
                    value,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
                guard bindCode == SQLITE_OK else {
                    if cancellationDetected(
                        code: bindCode,
                        database: database,
                        executionProbe: executionProbe
                    ) {
                        return .cancelled
                    }
                    return .failure(sqliteFailure(
                        stage: .rowInsertion,
                        database: database,
                        code: bindCode,
                        fallback: "Could not bind a full-text index row."
                    ))
                }
            }
            let stepCode = sqlite3_step(statement)
            guard stepCode == SQLITE_DONE else {
                if cancellationDetected(
                    code: stepCode,
                    database: database,
                    executionProbe: executionProbe
                ) {
                    return .cancelled
                }
                return .failure(sqliteFailure(
                    stage: .rowInsertion,
                    database: database,
                    code: stepCode,
                    fallback: "Could not write a full-text index row."
                ))
            }
            executionProbe.didInsertRow()
        }
        let commitCode = sqlite3_exec(database, "COMMIT", nil, nil, nil)
        guard commitCode == SQLITE_OK else {
            if cancellationDetected(
                code: commitCode,
                database: database,
                executionProbe: executionProbe
            ) {
                return .cancelled
            }
            return .failure(sqliteFailure(
                stage: .rowInsertion,
                database: database,
                code: commitCode,
                fallback: "Could not commit the full-text index transaction."
            ))
        }
        transactionCommitted = true
        return .success
    }

    private static func boundedMessageBody(_ body: String) -> String? {
        let bounded = KanameTextBounds.utf8Prefix(
            body.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumBytes: maximumMessageBodyBytes
        )
        return bounded.isEmpty ? nil : bounded
    }

    private static func containsNonWhitespace(_ value: String) -> Bool {
        value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil
    }

    private static func hasEligibleDetail(_ worktree: DesktopWorktreeRecord) -> Bool {
        !worktree.branch.isEmpty
            || !worktree.testSummary.isEmpty
            || !worktree.diagnosticSummary.isEmpty
            || containsNonWhitespace(worktree.diffSummary)
    }

    private static func worktreeDetail(_ worktree: DesktopWorktreeRecord) -> String? {
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
        return detail.isEmpty ? nil : detail
    }

    private static func contentFingerprint(components: [String?]) -> String {
        var hasher = SHA256()
        for component in components {
            guard let component else {
                hasher.update(data: Data([0]))
                continue
            }
            hasher.update(data: Data([1]))
            var byteCount = UInt64(component.utf8.count).bigEndian
            withUnsafeBytes(of: &byteCount) { bytes in
                hasher.update(data: Data(bytes))
            }
            hasher.update(data: Data(component.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func cancellationDetected(
        code: Int32,
        database: OpaquePointer?,
        executionProbe: ExecutionProbe
    ) -> Bool {
        guard code == SQLITE_INTERRUPT || executionProbe.cancellationRequested() else { return false }
        if let database { sqlite3_interrupt(database) }
        return true
    }

    private static func sqliteFailure(
        stage: Failure.Stage,
        database: OpaquePointer?,
        code: Int32,
        fallback: String
    ) -> Failure {
        let reason: String
        if let database, let message = sqlite3_errmsg(database) {
            reason = String(cString: message)
        } else if let message = sqlite3_errstr(code) {
            reason = String(cString: message)
        } else {
            reason = fallback
        }
        return Failure(stage: stage, reason: reason)
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
