import Foundation

public enum DesktopCodingPreviewTabState: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
    case closed

    public var label: String { rawValue.capitalized }
}

/// Desktop-only WKWebView preview tab metadata for a coding thread.
public struct DesktopCodingPreviewTabRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var threadID: String
    public var title: String
    public var url: String
    public var state: DesktopCodingPreviewTabState
    public var lastError: String?
    public var updatedAtUnixMillis: Int64

    public static func make(
        id: String,
        threadID: String,
        title: String,
        url: String,
        state: DesktopCodingPreviewTabState = .idle,
        lastError: String? = nil,
        updatedAtUnixMillis: Int64
    ) -> DesktopCodingPreviewTabRecord {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: Any] = [
            "id": id,
            "threadID": threadID,
            "title": trimmedTitle.isEmpty ? (URL(string: trimmedURL)?.host ?? "Preview") : trimmedTitle,
            "url": trimmedURL,
            "state": state.rawValue,
            "updatedAtUnixMillis": updatedAtUnixMillis,
        ]
        if let lastError { payload["lastError"] = lastError }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(DesktopCodingPreviewTabRecord.self, from: data)
    }
}

/// Approval metadata for injecting the curated Kaname preview MCP bridge.
/// Arbitrary user MCP remains blocked by CodexMCPIsolation.
public enum CodingPreviewMCPGrant {
    public static let actionKind = "coding.preview_mcp_grant"
    public static let curatedServerName = "kaname-preview"
    public static let defaultExpirySeconds: TimeInterval = 15 * 60

    public static let curatedToolAllowlist: [String] = [
        "preview.snapshot",
        "preview.click",
        "preview.type",
        "preview.scroll",
        "preview.evaluate",
        "preview.wait",
        "obsidian.search",
        "obsidian.read",
        "repo.search",
    ]

    public static func exactTarget(
        threadID: String,
        worktreePath: String,
        allowlistDigest: String
    ) -> String {
        "preview-mcp:\(threadID):\(worktreePath):sha256=\(allowlistDigest)"
    }

    public static func allowlistDigest() -> String {
        let joined = curatedToolAllowlist.joined(separator: "\n")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    public static func isLocalPreviewURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
            && (url.scheme == "http" || url.scheme == "https")
    }
}
