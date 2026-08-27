import Foundation

/// Per-turn git checkpoint bracket for mid-iteration rollback inside an
/// isolated coding worktree. Revert remains approval-gated.
public struct DesktopCodingCheckpointRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var threadID: String
    public var worktreeID: String
    public var turnID: String
    public var beforeRef: String
    public var afterRef: String?
    public var diffSummary: String
    public var diffStat: String
    public var createdAtUnixMillis: Int64

    public static func make(
        id: String,
        threadID: String,
        worktreeID: String,
        turnID: String,
        beforeRef: String,
        afterRef: String? = nil,
        diffSummary: String = "",
        diffStat: String = "",
        createdAtUnixMillis: Int64
    ) -> DesktopCodingCheckpointRecord {
        var payload: [String: Any] = [
            "id": id,
            "threadID": threadID,
            "worktreeID": worktreeID,
            "turnID": turnID,
            "beforeRef": beforeRef,
            "diffSummary": diffSummary,
            "diffStat": diffStat,
            "createdAtUnixMillis": createdAtUnixMillis,
        ]
        if let afterRef { payload["afterRef"] = afterRef }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(DesktopCodingCheckpointRecord.self, from: data)
    }

    public var approvalExactTarget: String { "checkpoint:\(id)" }

    public var hasAfterBracket: Bool { afterRef != nil }
}
