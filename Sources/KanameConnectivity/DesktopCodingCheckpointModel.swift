import Foundation

/// Per-turn git checkpoint bracket for mid-iteration rollback inside an
/// isolated coding worktree. Revert remains approval-gated.
public struct DesktopCodingCheckpointRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var threadID: String
    public var worktreeID: String
    public var turnID: String
    public var beforeRef: String
    public var beforeHeadRevision: String?
    public var beforeIndexTree: String?
    public var beforeWorktreeTree: String?
    public var beforeFingerprint: String?
    public var afterRef: String?
    public var afterHeadRevision: String?
    public var afterIndexTree: String?
    public var afterWorktreeTree: String?
    public var afterFingerprint: String?
    public var diffSummary: String
    public var diffStat: String
    public var createdAtUnixMillis: Int64

    public static func make(
        id: String,
        threadID: String,
        worktreeID: String,
        turnID: String,
        beforeRef: String,
        beforeHeadRevision: String? = nil,
        beforeIndexTree: String? = nil,
        beforeWorktreeTree: String? = nil,
        beforeFingerprint: String? = nil,
        afterRef: String? = nil,
        afterHeadRevision: String? = nil,
        afterIndexTree: String? = nil,
        afterWorktreeTree: String? = nil,
        afterFingerprint: String? = nil,
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
        if let beforeHeadRevision { payload["beforeHeadRevision"] = beforeHeadRevision }
        if let beforeIndexTree { payload["beforeIndexTree"] = beforeIndexTree }
        if let beforeWorktreeTree { payload["beforeWorktreeTree"] = beforeWorktreeTree }
        if let beforeFingerprint { payload["beforeFingerprint"] = beforeFingerprint }
        if let afterRef { payload["afterRef"] = afterRef }
        if let afterHeadRevision { payload["afterHeadRevision"] = afterHeadRevision }
        if let afterIndexTree { payload["afterIndexTree"] = afterIndexTree }
        if let afterWorktreeTree { payload["afterWorktreeTree"] = afterWorktreeTree }
        if let afterFingerprint { payload["afterFingerprint"] = afterFingerprint }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(DesktopCodingCheckpointRecord.self, from: data)
    }

    public func restoreTarget(worktreePath: String) -> GitCheckpointRestoreTarget? {
        guard let beforeHeadRevision, let beforeIndexTree, let beforeWorktreeTree, let beforeFingerprint,
              let afterRef, let afterHeadRevision, let afterIndexTree, let afterWorktreeTree, let afterFingerprint else {
            return nil
        }
        return GitCheckpointRestoreTarget(
            checkpointID: id,
            worktreePath: worktreePath,
            before: GitCheckpointSnapshot.captured(
                ref: beforeRef,
                headRevision: beforeHeadRevision,
                indexTree: beforeIndexTree,
                worktreeTree: beforeWorktreeTree,
                fingerprint: beforeFingerprint
            ),
            after: GitCheckpointSnapshot.captured(
                ref: afterRef,
                headRevision: afterHeadRevision,
                indexTree: afterIndexTree,
                worktreeTree: afterWorktreeTree,
                fingerprint: afterFingerprint
            )
        )
    }

    public func approvalExactTarget(worktreePath: String) -> String? {
        restoreTarget(worktreePath: worktreePath)?.approvalExactTarget
    }

    public var hasAfterBracket: Bool {
        afterRef != nil && afterFingerprint != nil && beforeFingerprint != nil
    }
}
