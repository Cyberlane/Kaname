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
        #expect(
            DesktopComposerSkillPicker.selectedSkillNames(in: "Try $mori-review and $obsidian-cli here")
                == ["mori-review", "obsidian-cli"]
        )
    }
}
