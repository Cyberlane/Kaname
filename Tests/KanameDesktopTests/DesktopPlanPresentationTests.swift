import Testing
@testable import KanameDesktop

struct DesktopPlanPresentationTests {
    @Test
    func emptyPlanHasAnHonestCountAndReviewState() {
        let presentation = DesktopPlanPresentation(items: [], phase: .awaitingApproval)

        #expect(presentation.rows.isEmpty)
        #expect(presentation.stepCountLabel == "0 steps")
        #expect(presentation.progressLabel == "0 steps")
        #expect(presentation.accessibilityLabel == "Implementation plan. Awaiting your review. 0 steps.")
    }

    @Test
    func savedPlanExplainsThatItHasNoActiveAuthority() {
        let presentation = DesktopPlanPresentation(
            items: [DesktopPlanItem(id: "saved", title: "Preserved step", state: .complete)],
            phase: .saved
        )

        #expect(presentation.phase.label == "Saved plan")
        #expect(presentation.phase.detail.contains("no active implementation authority"))
        #expect(presentation.progressLabel == "1 of 1 complete")
    }

    @Test
    func mixedPlanPreservesProviderOrderIdentityAndSemanticStatus() {
        let presentation = DesktopPlanPresentation(
            items: [
                DesktopPlanItem(id: "inspect", title: "Inspect the existing flow", state: .complete),
                DesktopPlanItem(id: "implement", title: "Implement the bounded change", state: .inProgress),
                DesktopPlanItem(id: "verify", title: "Verify the result", state: .pending),
            ],
            phase: .implementing
        )

        #expect(presentation.rows.map(\.id) == ["inspect", "implement", "verify"])
        #expect(presentation.rows.map(\.ordinal) == [1, 2, 3])
        #expect(presentation.rows.map(\.statusLabel) == ["Complete", "In progress", "Pending"])
        #expect(presentation.rows.map(\.statusSymbol) == ["checkmark.circle.fill", "circle.dotted", "circle"])
        #expect(presentation.rows.map(\.isCurrent) == [false, true, false])
        #expect(presentation.progressLabel == "1 of 3 complete")
    }

    @Test
    func approvalReviewCallsUnstartedWorkPlannedRatherThanPending() throws {
        let presentation = DesktopPlanPresentation(
            items: [DesktopPlanItem(id: "one", title: "A bounded step", state: .pending)],
            phase: .awaitingApproval
        )
        let row = try #require(presentation.rows.first)

        #expect(row.statusLabel == "Planned")
        #expect(row.accessibilityLabel == "Step 1 of 1: A bounded step. Status: Planned.")
    }

    @Test
    func longProviderTitlesRemainLossless() throws {
        let title = String(repeating: "Review the authorization boundary carefully. ", count: 40)
        let presentation = DesktopPlanPresentation(
            items: [DesktopPlanItem(id: "long", title: title, state: .pending)],
            phase: .drafting
        )

        #expect(try #require(presentation.rows.first).title == title)
    }
}
