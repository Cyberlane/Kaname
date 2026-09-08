import Foundation

public enum DesktopComposerTriggerPlacement: Sendable {
    case lineStart
    case beforeCursorOnLine
}

public struct DesktopComposerInlineQuery: Equatable, Sendable {
    public let fragment: String
    public let triggerRange: Range<Int>

    public init(fragment: String, triggerRange: Range<Int>) {
        self.fragment = fragment
        self.triggerRange = triggerRange
    }
}

public enum DesktopComposerInlineQueries {
    public static func query(
        in text: String,
        cursorOffset: Int,
        hasSelection: Bool = false,
        trigger: Character,
        placement: DesktopComposerTriggerPlacement
    ) -> DesktopComposerInlineQuery? {
        guard !hasSelection, cursorOffset >= 0, cursorOffset <= text.count else { return nil }
        let cursor = text.index(text.startIndex, offsetBy: cursorOffset)
        let prefix = text[..<cursor]
        let lineStart = prefix.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex

        let triggerIndex: String.Index?
        switch placement {
        case .lineStart:
            if lineStart < text.endIndex, text[lineStart] == trigger {
                triggerIndex = lineStart
            } else {
                triggerIndex = nil
            }
        case .beforeCursorOnLine:
            triggerIndex = text[lineStart..<cursor].lastIndex(of: trigger)
        }
        guard let triggerIndex else { return nil }

        let queryStart = text.index(after: triggerIndex)
        guard cursor >= queryStart else { return nil }
        var tokenEnd = queryStart
        while tokenEnd < text.endIndex, !text[tokenEnd].isWhitespace {
            tokenEnd = text.index(after: tokenEnd)
        }
        guard cursor <= tokenEnd else { return nil }

        let triggerStart = text.distance(from: text.startIndex, to: triggerIndex)
        let triggerEnd = text.distance(from: text.startIndex, to: tokenEnd)
        return DesktopComposerInlineQuery(
            fragment: String(text[queryStart..<cursor]),
            triggerRange: triggerStart..<triggerEnd
        )
    }

    public static func consuming(
        _ query: DesktopComposerInlineQuery,
        replacement: String,
        from text: String
    ) -> (text: String, insertionOffset: Int)? {
        guard query.triggerRange.lowerBound >= 0,
              query.triggerRange.upperBound <= text.count else { return nil }
        let lowerBound = text.index(text.startIndex, offsetBy: query.triggerRange.lowerBound)
        let upperBound = text.index(text.startIndex, offsetBy: query.triggerRange.upperBound)
        var updated = text
        updated.removeSubrange(lowerBound..<upperBound)
        updated.insert(contentsOf: replacement, at: lowerBound)
        return (updated, query.triggerRange.lowerBound + replacement.count)
    }

    public static func rankedMatches<Item>(
        query: DesktopComposerInlineQuery,
        in items: [Item],
        normalizedQuery: (String) -> String = normalized,
        rank: (Item, String) -> Int?
    ) -> [Item] {
        let needle = normalizedQuery(query.fragment)
        guard !needle.isEmpty else { return items }

        return items.enumerated().compactMap { index, item -> (Int, Int, Item)? in
            guard let score = rank(item, needle) else { return nil }
            return (score, index, item)
        }
        .sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        .map(\.2)
    }

    public static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
