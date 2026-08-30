@testable import KanameDesktop
import Testing

struct DesktopWorkspaceChromePresentationTests {
    @Test
    func workspaceWidthSelectsPersistentOrTransientInspectorPresentation() {
        let visible = DesktopWorkspaceChromePresentation(
            availableWidth: DesktopWorkspaceChromePresentation.splitInspectorMinimumWidth,
            splitInspectorVisible: true,
            compactInspectorPresented: false
        )
        let hidden = DesktopWorkspaceChromePresentation(
            availableWidth: 1_240,
            splitInspectorVisible: false,
            compactInspectorPresented: true
        )

        #expect(!visible.usesCompactLayout)
        #expect(visible.inspectorPlacement == .split)
        #expect(visible.inspectorToggleAction == .setSplitVisible(false))
        #expect(visible.inspectorToggleTitle == "Hide Inspector")

        #expect(hidden.inspectorPlacement == .hidden)
        #expect(hidden.inspectorToggleAction == .setSplitVisible(true))
        #expect(hidden.inspectorToggleTitle == "Show Inspector")

        let compactHidden = DesktopWorkspaceChromePresentation(
            availableWidth: 979,
            splitInspectorVisible: true,
            compactInspectorPresented: false
        )
        let presented = DesktopWorkspaceChromePresentation(
            availableWidth: 720,
            splitInspectorVisible: false,
            compactInspectorPresented: true
        )

        #expect(compactHidden.usesCompactLayout)
        #expect(compactHidden.inspectorPlacement == .hidden)
        #expect(compactHidden.inspectorToggleAction == .setCompactPopoverPresented(true))
        #expect(compactHidden.inspectorToggleTitle == "Show Inspector")

        #expect(presented.inspectorPlacement == .popover)
        #expect(presented.inspectorToggleAction == .setCompactPopoverPresented(false))
        #expect(presented.inspectorToggleTitle == "Close Inspector")
        #expect(presented.inspectorToggleSystemImage == "xmark")
    }

    @Test
    func invalidWidthsFailClosedToCompactPresentation() {
        let negative = DesktopWorkspaceChromePresentation(
            availableWidth: -40,
            splitInspectorVisible: true,
            compactInspectorPresented: false
        )
        let nonFinite = DesktopWorkspaceChromePresentation(
            availableWidth: .infinity,
            splitInspectorVisible: true,
            compactInspectorPresented: false
        )

        #expect(negative.availableWidth == 0)
        #expect(nonFinite.availableWidth == 0)
        #expect(negative.usesCompactLayout)
        #expect(nonFinite.usesCompactLayout)
    }
}
