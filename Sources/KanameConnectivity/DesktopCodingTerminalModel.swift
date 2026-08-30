import Foundation

public enum DesktopCodingTerminalState: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case running
    case exited
    case closed

    public var label: String { rawValue.capitalized }
}

public struct DesktopCodingTerminalKey: Hashable, Sendable {
    public let threadID: String
    public let terminalID: String

    public init(threadID: String, terminalID: String) {
        self.threadID = threadID
        self.terminalID = terminalID
    }
}

/// Coding-thread terminal metadata with bounded prompt excerpt and optional
/// interactive PTY session identity (PID, geometry, discovered ports).
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
    public var processID: Int32?
    public var columns: UInt16?
    public var rows: UInt16?
    public var discoveredPreviewPorts: [UInt16]
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
        processID: Int32? = nil,
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        discoveredPreviewPorts: [UInt16] = [],
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
            "discoveredPreviewPorts": discoveredPreviewPorts.map { Int($0) },
            "updatedAtUnixMillis": updatedAtUnixMillis,
        ]
        if let worktreeID { payload["worktreeID"] = worktreeID }
        if let activeCommand { payload["activeCommand"] = activeCommand }
        if let processID { payload["processID"] = Int(processID) }
        if let columns { payload["columns"] = Int(columns) }
        if let rows { payload["rows"] = Int(rows) }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(DesktopCodingTerminalRecord.self, from: data)
    }

    public var hasAttachableExcerpt: Bool {
        !scrollbackExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var key: DesktopCodingTerminalKey {
        DesktopCodingTerminalKey(threadID: threadID, terminalID: id)
    }

    private enum CodingKeys: String, CodingKey {
        case id, threadID, worktreeID, label, cwd, scrollbackDigest, scrollbackExcerpt
        case activeCommand, state, processID, columns, rows, discoveredPreviewPorts, updatedAtUnixMillis
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        threadID = try container.decode(String.self, forKey: .threadID)
        worktreeID = try container.decodeIfPresent(String.self, forKey: .worktreeID)
        label = try container.decode(String.self, forKey: .label)
        cwd = try container.decode(String.self, forKey: .cwd)
        scrollbackDigest = try container.decode(String.self, forKey: .scrollbackDigest)
        scrollbackExcerpt = try container.decode(String.self, forKey: .scrollbackExcerpt)
        activeCommand = try container.decodeIfPresent(String.self, forKey: .activeCommand)
        state = try container.decode(DesktopCodingTerminalState.self, forKey: .state)
        if let process = try container.decodeIfPresent(Int.self, forKey: .processID) {
            processID = Int32(process)
        } else {
            processID = nil
        }
        if let columns = try container.decodeIfPresent(Int.self, forKey: .columns) {
            self.columns = UInt16(clamping: columns)
        } else {
            self.columns = nil
        }
        if let rows = try container.decodeIfPresent(Int.self, forKey: .rows) {
            self.rows = UInt16(clamping: rows)
        } else {
            self.rows = nil
        }
        let ports = try container.decodeIfPresent([Int].self, forKey: .discoveredPreviewPorts) ?? []
        discoveredPreviewPorts = ports.map { UInt16(clamping: $0) }
        updatedAtUnixMillis = try container.decode(Int64.self, forKey: .updatedAtUnixMillis)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(threadID, forKey: .threadID)
        try container.encodeIfPresent(worktreeID, forKey: .worktreeID)
        try container.encode(label, forKey: .label)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(scrollbackDigest, forKey: .scrollbackDigest)
        try container.encode(scrollbackExcerpt, forKey: .scrollbackExcerpt)
        try container.encodeIfPresent(activeCommand, forKey: .activeCommand)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(processID.map(Int.init), forKey: .processID)
        try container.encodeIfPresent(columns.map(Int.init), forKey: .columns)
        try container.encodeIfPresent(rows.map(Int.init), forKey: .rows)
        try container.encode(discoveredPreviewPorts.map(Int.init), forKey: .discoveredPreviewPorts)
        try container.encode(updatedAtUnixMillis, forKey: .updatedAtUnixMillis)
    }
}
