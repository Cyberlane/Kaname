import Foundation
@testable import KanameDesktop
import Testing

struct DesktopComposerCommandTests {
    @Test
    func catalogIsStableAndDescribesEveryLocalAction() {
        let commands = DesktopComposerCommands.catalog()

        #expect(commands.map(\.id) == DesktopComposerCommandID.allCases)
        #expect(commands.allSatisfy { !$0.invocation.isEmpty && !$0.title.isEmpty && !$0.detail.isEmpty })
        #expect(commands.allSatisfy { $0.isEnabled })
    }

    @Test
    func queryUsesTheInsertionPointAndOnlyTheCurrentLineToken() throws {
        let text = "Earlier 🙂 text\n/pla keep this"
        let (query, edit) = try resolvedQueryAndEdit(in: text, cursorAfter: "/pla")

        #expect(query.fragment == "pla")
        #expect(query.triggerRange == 15..<19)
        #expect(edit.text == "Earlier 🙂 text\n keep this")
        #expect(edit.insertionOffset == 15)
    }

    @Test
    func queryIsUnicodeSafeWhenTheCursorSitsInsideACommandToken() throws {
        let text = "日本語👩🏽‍💻\n/plan後続"
        let (query, edit) = try resolvedQueryAndEdit(in: text, cursorAfter: "/plan")

        #expect(query.fragment == "plan")
        #expect(edit.text == "日本語👩🏽‍💻\n")
        #expect(edit.insertionOffset == 5)
    }

    @Test
    func selectionProjectionHandlesCurrentUnicodeAndAStalePreviousDraftIndex() {
        let currentDraft = "日本語👩🏽‍💻xyz"
        let currentLowerBound = currentDraft.index(currentDraft.startIndex, offsetBy: 3)
        let currentUpperBound = currentDraft.index(after: currentLowerBound)
        #expect(DesktopComposerSelectionProjection.project(
            currentLowerBound..<currentUpperBound,
            in: currentDraft,
            fallbackCursorOffset: nil
        ) == DesktopComposerSelectionProjection(
            cursorOffset: 3,
            hasSelection: true,
            recoveredStaleSelection: false
        ))

        let previousDraft = "abcdef"
        let staleLowerBound = previousDraft.index(previousDraft.startIndex, offsetBy: 4)
        let replacementDraft = "x"
        #expect(DesktopComposerSelectionProjection.project(
            staleLowerBound..<previousDraft.endIndex,
            in: replacementDraft,
            fallbackCursorOffset: 42
        ) == DesktopComposerSelectionProjection(
            cursorOffset: 1,
            hasSelection: false,
            recoveredStaleSelection: true
        ))
    }

    @Test
    func queryRejectsSelectionsArgumentsAndSlashInsideProse() throws {
        let selectedText = "/plan"
        let selectionEnd = selectedText.endIndex
        let selectionStart = selectedText.index(before: selectionEnd)
        #expect(DesktopComposerCommands.query(
            in: selectedText,
            selection: selectionStart..<selectionEnd
        ) == nil)

        let withArguments = "/plan review this"
        #expect(DesktopComposerCommands.query(in: withArguments) == nil)
        #expect(DesktopComposerCommands.query(in: "Please use /plan") == nil)
        #expect(DesktopComposerCommands.query(in: "https://example.com") == nil)
    }

    @Test
    func filteringRanksExactThenPrefixAndKeepsCatalogOrder() throws {
        let commands = DesktopComposerCommands.catalog()
        let exact = try #require(DesktopComposerCommands.query(in: "/runtime"))
        #expect(DesktopComposerCommands.matching(exact, in: commands).map(\.id).first == .runtime)

        let prefix = try #require(DesktopComposerCommands.query(in: "/r"))
        #expect(DesktopComposerCommands.matching(prefix, in: commands).map(\.id) == [.runtime, .rename])

        let widthFolded = try #require(DesktopComposerCommands.query(in: "/ｍｏ"))
        #expect(DesktopComposerCommands.matching(widthFolded, in: commands).map(\.id).first == .model)
    }

    @Test
    func selectionMovesCyclicallyAcrossTheFilteredCatalog() {
        let commands = [
            DesktopComposerCommand(id: .chat),
            DesktopComposerCommand(id: .diff, disabledReason: "Unavailable"),
            DesktopComposerCommand(id: .plan),
        ]
        var selection = DesktopComposerCommandSelectionState()

        selection.reconcile(with: commands)
        #expect(selection.selectedCommandID == .chat)
        selection.move(.previous, in: commands)
        #expect(selection.selectedCommandID == .plan)
        selection.move(.next, in: commands)
        #expect(selection.selectedCommandID == .chat)
        selection.move(.next, in: commands)
        #expect(selection.selectedCommandID == .diff)
    }

    @Test
    func resolutionSeparatesLocalDisabledAndUnknownSubmissions() throws {
        let commands = DesktopComposerCommands.catalog { command in
            command == .runtime ? "Runtime settings are locked while work is active." : nil
        }
        let planQuery = try #require(DesktopComposerCommands.query(in: "Keep me\n/plan"))
        #expect(DesktopComposerCommands.resolveSubmission(
            text: "Keep me\n/plan",
            query: planQuery,
            selectedCommandID: .plan,
            commands: commands
        ) == .local(.plan, edit: DesktopComposerCommandEdit(text: "Keep me\n", insertionOffset: 8)))

        let runtimeQuery = try #require(DesktopComposerCommands.query(in: "/runtime"))
        #expect(DesktopComposerCommands.resolveSubmission(
            text: "/runtime",
            query: runtimeQuery,
            selectedCommandID: .runtime,
            commands: commands
        ) == .disabled(.runtime, reason: "Runtime settings are locked while work is active."))

        let unknown = try #require(DesktopComposerCommands.query(in: "/provider-native-command"))
        #expect(DesktopComposerCommands.resolveSubmission(
            text: "/provider-native-command",
            query: unknown,
            selectedCommandID: nil,
            commands: commands
        ) == .message)
    }

    @Test
    func composerPresentationStartsCompactStaysReadableAndCapsAtEightLines() {
        #expect(DesktopComposerPresentation.minimumLines == 1)
        #expect(DesktopComposerPresentation.maximumLines == 8)
        #expect(DesktopComposerPresentation.inputPointSize == 16)
        #expect(DesktopComposerPresentation.toolbarPointSize >= 13)
        #expect(DesktopComposerPresentation.contextPointSize >= 12.5)
        #expect(DesktopComposerPresentation.maximumWidth == 760)
    }

    private func resolvedQueryAndEdit(
        in text: String,
        cursorAfter token: String
    ) throws -> (DesktopComposerCommandQuery, DesktopComposerCommandEdit) {
        let cursor = try #require(text.range(of: token)?.upperBound)
        let query = try #require(DesktopComposerCommands.query(
            in: text,
            selection: cursor..<cursor
        ))
        let edit = try #require(DesktopComposerCommands.consuming(query, from: text))
        return (query, edit)
    }
}
