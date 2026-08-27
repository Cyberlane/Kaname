import Foundation

public enum DesktopCodingTerminalState: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case running
    case exited
    case closed

    public var label: String { rawValue.capitalized }
}

/// Phase A coding-thread terminal metadata with a bounded prompt excerpt.
/// Full PTY hosting is deferred; Kaname records scrollback from bounded
/// subprocess captures and human-attached output.
public struct DesktopCodingTerminalRecord: Codable, Equatable, Identifiable, Sendable {
    public static let defaultTerminalID = "term-1"
    public static let maximumExcerptBytes = 16 * 1_024
    public static let maximumScrollbackBytes = 256 * 1_024

    public let id: String
    public var threadID: String
    public var worktreeID: String?
    public var label: String
    public var cwd: String
    public var scrollbackDigest: String
    public var scrollbackExcerpt: String
    public var activeCommand: String?
    public var state: DesktopCodingTerminalState
    public var updatedAtUnixMillis: Int64

    public static func make(
        id: String = DesktopCodingTerminalRecord.defaultTerminalID,
        threadID: String,
        worktreeID: String? = nil,
        label: String = "Terminal",
        cwd: String,
        scrollbackDigest: String = "",
        scrollbackExcerpt: String = "",
        activeCommand: String? = nil,
        state: DesktopCodingTerminalState = .idle,
        updatedAtUnixMillis: Int64
    ) -> DesktopCodingTerminalRecord {
        var payload: [String: Any] = [
            "id": id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTerminalID : id,
            "threadID": threadID,
            "label": label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Terminal" : label,
            "cwd": cwd,
            "scrollbackDigest": scrollbackDigest,
            "scrollbackExcerpt": scrollbackExcerpt,
            "state": state.rawValue,
            "updatedAtUnixMillis": updatedAtUnixMillis,
        ]
        if let worktreeID { payload["worktreeID"] = worktreeID }
        if let activeCommand { payload["activeCommand"] = activeCommand }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(DesktopCodingTerminalRecord.self, from: data)
    }

    public var hasAttachableExcerpt: Bool {
        !scrollbackExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
