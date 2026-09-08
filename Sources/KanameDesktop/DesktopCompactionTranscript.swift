import Foundation
import KanameDomain

/// Builds the bounded, chronological transcript supplied to the optional
/// compaction summarizer. The cutoff is inclusive because the compaction
/// digest replaces every message through that point.
public enum DesktopCompactionTranscript {
    public static let maximumBytes = 40_000
    public static let maximumMessageBytes = 3_000

    public static func bounded(
        thread: DesktopThread,
        throughMessageID: String
    ) -> String {
        guard let cutoffIndex = thread.messages.firstIndex(where: { $0.id == throughMessageID }) else {
            return ""
        }
        var lines: [String] = []
        var budget = maximumBytes
        for message in thread.messages[...cutoffIndex].reversed() where message.role != .system {
            let role = message.role == .user ? "User" : "Assistant"
            let body = KanameTextBounds.utf8Prefix(
                message.body.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumBytes: maximumMessageBytes
            )
            let line = "\(role): \(body)"
            budget -= line.utf8.count + (lines.isEmpty ? 0 : 2)
            if budget < 0 { break }
            lines.append(line)
        }
        return lines.reversed().joined(separator: "\n\n")
    }
}
