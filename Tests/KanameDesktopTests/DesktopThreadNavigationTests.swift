import Testing
@testable import KanameDesktop

struct DesktopThreadNavigationTests {
    @Test
    func threadPanelsKeepCanonicalOrderAndOnlyCodingThreadsShowKnowledge() {
        let codingPanels = DesktopThreadPanel.available(forCodingThread: true)
        #expect(codingPanels == [
            .conversation, .plan, .changes, .evidence, .knowledge,
        ])
        #expect(DesktopThreadPanel.available(forCodingThread: false) == [
            .conversation, .plan, .changes, .evidence,
        ])
        #expect(DesktopThreadPanel.allCases.map(\.label) == [
            "Chat", "Plan", "Changes", "Evidence", "Knowledge",
        ])
        #expect(DesktopCyclicSelection.moving(.conversation, .next, in: codingPanels) == .plan)
        #expect(DesktopCyclicSelection.moving(.knowledge, .next, in: codingPanels) == .conversation)
    }

    @Test
    func workflowPresentationRoutesNavigationWithoutOwningDecisionActions() {
        let presentations = Dictionary(uniqueKeysWithValues: DesktopCodingWorkflowStage.allCases.map {
            ($0, DesktopCodingWorkflowPresentation(stage: $0))
        })

        #expect(presentations[.discuss]?.ownerPanel == .conversation)
        #expect(presentations[.planning]?.ownerPanel == .plan)
        #expect(presentations[.planReview]?.ownerPanel == .plan)
        #expect(presentations[.preparing]?.ownerPanel == .changes)
        #expect(presentations[.implementing]?.ownerPanel == .changes)
        #expect(presentations[.implementationReview]?.ownerPanel == .changes)
        #expect(presentations[.evidenceReview]?.ownerPanel == .evidence)
        #expect(presentations[.knowledgeReview]?.ownerPanel == .knowledge)
        #expect(presentations[.completed]?.ownerPanel == nil)
        #expect(presentations[.rejected]?.ownerPanel == .changes)
        #expect(presentations[.failed]?.ownerPanel == nil)
    }

    @Test
    func reviewAndRecoveryStagesMarkTheOwningPanelForAttention() {
        let attentionPanels = DesktopCodingWorkflowStage.allCases.map {
            DesktopCodingWorkflowPresentation(stage: $0).attentionPanel
        }

        #expect(attentionPanels == [
            nil,
            nil,
            .plan,
            nil,
            nil,
            .changes,
            .evidence,
            .knowledge,
            nil,
            .changes,
            nil,
        ])
        #expect(DesktopCodingWorkflowPresentation(stage: .planReview).symbol == "hand.raised.fill")
    }

    @Test
    func compactStatusLabelsExposeExactProgress() {
        #expect(DesktopCodingWorkflowPresentation(stage: .planReview).compactLabel == "Plan approval · 3/7")
        #expect(DesktopCodingWorkflowPresentation(stage: .implementationReview).compactLabel == "Review changes · 5/7")
        #expect(DesktopCodingWorkflowPresentation(stage: .evidenceReview).compactLabel == "Review evidence · 6/7")
        #expect(DesktopCodingWorkflowPresentation(stage: .knowledgeReview).compactLabel == "Knowledge update · 7/7")
        #expect(DesktopCodingWorkflowPresentation.workflowPath.contains("Review evidence"))
    }
}
