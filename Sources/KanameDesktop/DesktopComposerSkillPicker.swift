import Foundation

public struct DesktopComposerSkill: Identifiable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let path: String

    public var id: String { path }
}

public struct DesktopComposerSkillQuery: Equatable, Sendable {
    public let fragment: String
    public let triggerRange: Range<Int>

    public init(fragment: String, triggerRange: Range<Int>) {
        self.fragment = fragment
        self.triggerRange = triggerRange
    }

    fileprivate init(inline: DesktopComposerInlineQuery) {
        fragment = inline.fragment
        triggerRange = inline.triggerRange
    }

    fileprivate var inline: DesktopComposerInlineQuery {
        DesktopComposerInlineQuery(fragment: fragment, triggerRange: triggerRange)
    }
}

public struct DesktopComposerSkillEdit: Equatable, Sendable {
    public let text: String
    public let insertionOffset: Int
    public let selectedSkillName: String
}

public enum DesktopComposerSkillPicker {
    public static func query(
        in text: String,
        cursorOffset: Int,
        hasSelection: Bool = false
    ) -> DesktopComposerSkillQuery? {
        guard let inline = DesktopComposerInlineQueries.query(
            in: text,
            cursorOffset: cursorOffset,
            hasSelection: hasSelection,
            trigger: "$",
            placement: .beforeCursorOnLine
        ) else { return nil }
        return DesktopComposerSkillQuery(inline: inline)
    }

    public static func matching(
        _ query: DesktopComposerSkillQuery,
        in skills: [DesktopComposerSkill]
    ) -> [DesktopComposerSkill] {
        DesktopComposerInlineQueries.rankedMatches(query: query.inline, in: skills) { skill, normalizedQuery in
            let name = DesktopComposerInlineQueries.normalized(skill.name)
            let description = DesktopComposerInlineQueries.normalized(skill.description)
            if name.hasPrefix(normalizedQuery) { return 0 }
            if name.contains(normalizedQuery) { return 1 }
            if description.contains(normalizedQuery) { return 2 }
            return nil
        }
    }

    public static func consuming(
        _ query: DesktopComposerSkillQuery,
        selectedSkill: DesktopComposerSkill,
        from text: String
    ) -> DesktopComposerSkillEdit? {
        guard let consumed = DesktopComposerInlineQueries.consuming(
            query.inline,
            replacement: "$\(selectedSkill.name) ",
            from: text
        ) else { return nil }
        return DesktopComposerSkillEdit(
            text: consumed.text,
            insertionOffset: consumed.insertionOffset,
            selectedSkillName: selectedSkill.name
        )
    }

    public static func skills(_ entries: [(name: String, description: String, path: String)]) -> [DesktopComposerSkill] {
        entries.map {
            DesktopComposerSkill(name: $0.name, description: $0.description, path: $0.path)
        }
    }

    public static func selectedSkillNames(
        in text: String,
        resolving resolve: (String) -> String?
    ) -> [String] {
        var names: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var remainder = line[...]
            while let range = remainder.range(of: "$") {
                remainder = remainder[range.upperBound...]
                let token = remainder.prefix(while: { !$0.isWhitespace })
                guard !token.isEmpty else { continue }
                if let name = resolve(String(token)) {
                    names.append(name)
                }
                remainder = remainder[token.endIndex...]
            }
        }
        return names
    }
}
