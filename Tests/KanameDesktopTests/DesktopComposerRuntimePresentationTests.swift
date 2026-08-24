import KanameDomain
@testable import KanameDesktop
import Testing

struct DesktopComposerRuntimePresentationTests {
    @Test
    func wideCodingComposerShowsOnlyGenuineRuntimeChoices() {
        let layout = DesktopComposerRuntimePresentation.layout(for: .coding, compact: false)

        #expect(layout.visibleControls == [.providerAndModel, .thinking])
        #expect(layout.overflowControls.isEmpty)
        #expect(!layout.visibleControls.contains(.access))
    }

    @Test
    func compactCodingComposerKeepsProviderVisibleAndMovesThinkingToOverflow() {
        let layout = DesktopComposerRuntimePresentation.layout(for: .coding, compact: true)

        #expect(layout.visibleControls == [.providerAndModel, .overflow])
        #expect(layout.overflowControls == [.thinking])
    }

    @Test
    func compactBoundaryKeepsProviderVisibleWithoutDuplicatingControls() {
        let compact = DesktopComposerRuntimePresentation.layout(
            for: .research,
            availableWidth: DesktopComposerRuntimePresentation.compactWidthThreshold - 1
        )
        let wide = DesktopComposerRuntimePresentation.layout(
            for: .research,
            availableWidth: DesktopComposerRuntimePresentation.compactWidthThreshold
        )

        #expect(compact.visibleControls.first == .providerAndModel)
        #expect(Set(compact.visibleControls).isDisjoint(with: compact.overflowControls))
        #expect(wide.visibleControls == [.providerAndModel, .thinking, .access])
    }

    @Test
    func nonCodingComposerKeepsRealAccessSelection() {
        let wide = DesktopComposerRuntimePresentation.layout(for: .research, compact: false)
        let compact = DesktopComposerRuntimePresentation.layout(for: .personal, compact: true)

        #expect(wide.visibleControls == [.providerAndModel, .thinking, .access])
        #expect(compact.visibleControls == [.providerAndModel, .overflow])
        #expect(compact.overflowControls == [.thinking, .access])
    }

    @Test
    func accessChoicesExplainConsequencesAndFlagFullAccess() {
        let choices = ConversationRuntimeMode.allCases.map(DesktopComposerRuntimePresentation.access)

        #expect(choices.map(\.title) == ["Supervised", "Auto-accept edits", "Auto", "Full access"])
        #expect(choices.allSatisfy { !$0.detail.isEmpty && !$0.systemImage.isEmpty })
        #expect(choices.map(\.isWarning) == [false, false, false, true])
    }

    @Test
    func knownProvidersReceiveDistinctVisualIdentities() {
        let symbols = ["Codex", "Claude", "OpenCode"].map(
            DesktopComposerRuntimePresentation.providerSystemImage
        )

        #expect(Set(symbols).count == 3)
        #expect(DesktopComposerRuntimePresentation.providerSystemImage("Custom") == "cpu")
    }
}
