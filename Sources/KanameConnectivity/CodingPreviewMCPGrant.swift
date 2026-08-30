import Foundation

/// Approval metadata for injecting the curated Kaname preview MCP bridge.
/// Arbitrary user MCP remains blocked by CodexMCPIsolation.
public enum CodingPreviewMCPGrant {
    public static let actionKind = "coding.preview_mcp_grant"
    public static let curatedServerName = "kaname-preview"
    public static let approvalTitle = "Grant curated preview MCP"
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
        allowlistDigest: String = allowlistDigest()
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
        guard url.baseURL == nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host?.lowercased(),
              hasValidAuthorityPort(in: url) else { return false }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
            ? String(rawHost.dropFirst().dropLast())
            : rawHost
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    private static func hasValidAuthorityPort(in url: URL) -> Bool {
        let absolute = url.absoluteString
        guard let schemeDelimiter = absolute.range(of: "://") else { return false }
        let authorityEnd = absolute[schemeDelimiter.upperBound...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? absolute.endIndex
        let authority = absolute[schemeDelimiter.upperBound ..< authorityEnd]
        guard !authority.isEmpty, !authority.contains("@") else { return false }

        let portText: Substring?
        if authority.first == "[" {
            guard let closingBracket = authority.firstIndex(of: "]") else { return false }
            let suffix = authority[authority.index(after: closingBracket)...]
            guard suffix.isEmpty || suffix.first == ":" else { return false }
            portText = suffix.isEmpty ? nil : suffix.dropFirst()
        } else {
            let separators = authority.indices.filter { authority[$0] == ":" }
            guard separators.count <= 1 else { return false }
            portText = separators.first.map { authority[authority.index(after: $0)...] }
        }

        guard let portText else { return true }
        guard !portText.isEmpty,
              portText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(portText),
              (1 ... 65_535).contains(port) else { return false }
        return true
    }

    /// Pure grant matcher so callers can supply approval fields without
    /// coupling Connectivity to Desktop snapshot types.
    public static func matchesApprovedGrant(
        title: String,
        exactTarget: String,
        threadID: String?,
        isApproved: Bool,
        expiresAtUnixMillis: Int64?,
        expectedThreadID: String,
        worktreePath: String,
        nowUnixMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> Bool {
        guard isApproved,
              threadID == expectedThreadID,
              title == approvalTitle,
              exactTarget == Self.exactTarget(threadID: expectedThreadID, worktreePath: worktreePath)
        else { return false }
        return expiresAtUnixMillis.map { $0 > nowUnixMillis } ?? true
    }
}
