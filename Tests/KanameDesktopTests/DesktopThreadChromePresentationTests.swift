@testable import KanameDesktop
import Testing

struct DesktopThreadChromePresentationTests {
    @Test
    func codingTabsKeepTheEstablishedFivePanelOrder() {
        #expect(DesktopThreadPanel.available(isCoding: true) == [
            .conversation,
            .plan,
            .changes,
            .evidence,
            .knowledge,
        ])
        #expect(DesktopThreadPanel.allCases.map(\.label) == [
            "Chat",
            "Plan",
            "Changes",
            "Evidence",
            "Knowledge",
        ])
    }

    @Test
    func nonCodingTabsOnlyOmitTheCodingKnowledgeLane() {
        #expect(DesktopThreadPanel.available(isCoding: false) == [
            .conversation,
            .plan,
            .changes,
            .evidence,
        ])
    }

    @Test
    func panelBadgesExposeOnlyNonzeroBoundedCounts() {
        let badges = DesktopThreadPanelBadges(plan: 4, changes: -2, evidence: 3, knowledge: 120)

        #expect(badges.count(for: .conversation) == nil)
        #expect(badges.count(for: .plan) == 4)
        #expect(badges.count(for: .changes) == nil)
        #expect(badges.count(for: .evidence) == 3)
        #expect(badges.count(for: .knowledge) == DesktopThreadPanelBadges.maximumVisibleCount)
    }

    @Test
    func workflowOnlyExpandsWhenADecisionOrFailureNeedsAttention() {
        let passive: [DesktopCodingWorkflowStage] = [
            .discuss,
            .planning,
            .preparing,
            .implementing,
            .completed,
        ]
        let expanded: [DesktopCodingWorkflowStage] = [
            .planReview,
            .implementationReview,
            .evidenceReview,
            .knowledgeReview,
            .rejected,
            .failed,
        ]

        #expect(passive.allSatisfy { !$0.needsExpandedPresentation })
        #expect(expanded.allSatisfy { $0.needsExpandedPresentation })
        #expect(DesktopCodingWorkflowStage.planReview.action == .approvePlan)
        #expect(DesktopCodingWorkflowStage.evidenceReview.action == .reviewEvidence)
        #expect(DesktopCodingWorkflowStage.failed.action == .none)
    }

    @Test
    func workflowPresentationNamesAndTracksAllSevenKanameGates() {
        #expect(DesktopCodingWorkflowStage.gateLabels == [
            "Discuss",
            "Plan",
            "Approve",
            "Implement",
            "Changes",
            "Evidence",
            "Knowledge",
        ])
        #expect(DesktopCodingWorkflowStage.planReview.progressLabel == "Gate 3 of 7 · Approve plan")
        #expect(DesktopCodingWorkflowStage.discuss.activeGateIndex == 0)
        #expect(DesktopCodingWorkflowStage.planReview.activeGateIndex == 2)
        #expect(DesktopCodingWorkflowStage.implementing.activeGateIndex == 3)
        #expect(DesktopCodingWorkflowStage.knowledgeReview.activeGateIndex == 6)
        #expect(DesktopCodingWorkflowStage.completed.activeGateIndex == 7)
        #expect(DesktopCodingWorkflowStage.planReview.gateState(at: 0) == .complete)
        #expect(DesktopCodingWorkflowStage.planReview.gateState(at: 2) == .current)
        #expect(DesktopCodingWorkflowStage.planReview.gateState(at: 3) == .upcoming)
        #expect(DesktopCodingWorkflowStage.completed.gateState(at: 6) == .complete)
        #expect(DesktopCodingWorkflowStage.failed.gateState(at: 0) == .stopped)
    }

    @Test
    func primaryComposerActionReflectsSendQueueStopAndCommandStates() {
        #expect(DesktopComposerPresentation.primaryAction(
            isRunning: false,
            hasSendableContent: true,
            canSend: true,
            isImportingAttachments: false,
            selectedCommandIsEnabled: nil
        ) == DesktopComposerPrimaryAction(kind: .send, isEnabled: true))

        #expect(DesktopComposerPresentation.primaryAction(
            isRunning: true,
            hasSendableContent: true,
            canSend: true,
            isImportingAttachments: false,
            selectedCommandIsEnabled: nil
        ) == DesktopComposerPrimaryAction(kind: .queue, isEnabled: true))

        #expect(DesktopComposerPresentation.primaryAction(
            isRunning: true,
            hasSendableContent: false,
            canSend: false,
            isImportingAttachments: false,
            selectedCommandIsEnabled: nil
        ) == DesktopComposerPrimaryAction(kind: .stop, isEnabled: true))

        #expect(DesktopComposerPresentation.primaryAction(
            isRunning: true,
            hasSendableContent: true,
            canSend: false,
            isImportingAttachments: false,
            selectedCommandIsEnabled: false
        ) == DesktopComposerPrimaryAction(kind: .run, isEnabled: false))
    }
}
