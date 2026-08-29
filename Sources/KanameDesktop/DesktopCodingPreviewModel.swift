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

// CodingPreviewMCPGrant lives in KanameConnectivity so Codex isolation and
// the curated MCP HTTP server share one fail-closed allowlist definition.
