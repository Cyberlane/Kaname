import Testing
@testable import KanameDesktop

struct DesktopComposerSkillPickerTests {
    @Test
    func queryDetectsDollarPrefixOnCurrentLine() {
        let query = DesktopComposerSkillPicker.query(in: "Please use $mor", cursorOffset: "Please use $mor".count)
        #expect(query?.fragment == "mor")
    }

    @Test
    func matchingPrefersNamePrefix() {
        let skills = [
            DesktopComposerSkill(name: "mori-review", description: "Structural review", path: "/a"),
            DesktopComposerSkill(name: "obsidian-cli", description: "Vault operations", path: "/b"),
        ]
        let matches = DesktopComposerSkillPicker.matching(
            DesktopComposerSkillQuery(fragment: "mor", triggerRange: 0..<4),
            in: skills
        )
        #expect(matches.map(\.name) == ["mori-review"])
    }

    @Test
    func consumingInsertsSelectedSkillToken() {
        let edit = DesktopComposerSkillPicker.consuming(
            DesktopComposerSkillQuery(fragment: "obs", triggerRange: 0..<4),
            selectedSkill: DesktopComposerSkill(name: "obsidian-cli", description: "Vault", path: "/b"),
            from: "$obs"
        )
        #expect(edit?.text == "$obsidian-cli ")
        #expect(edit?.selectedSkillName == "obsidian-cli")
    }

    @Test
    func selectedSkillNamesFindsInlineTokens() {
        let availableNames = Set(["mori-review", "obsidian-cli"])
        #expect(
            DesktopComposerSkillPicker.selectedSkillNames(
                in: "Try $mori-review and $obsidian-cli here",
                resolving: { availableNames.contains($0) ? $0 : nil }
            )
                == ["mori-review", "obsidian-cli"]
        )
    }

    @Test
    func unmatchedTokensIgnored() {
        let availableNames = Set(["mori-review-similarity"])

        #expect(
            DesktopComposerSkillPicker.selectedSkillNames(
                in: "Keep $HOME and $100 as text; load $mori-review-similarity",
                resolving: { availableNames.contains($0) ? $0 : nil }
            ) == ["mori-review-similarity"]
        )
    }
}
