import Foundation

public enum DesktopCyclicSelectionDirection: Sendable {
    case previous
    case next
}

public enum DesktopCyclicSelection {
    public static func moving<ID: Equatable>(
        _ selectedID: ID?,
        _ direction: DesktopCyclicSelectionDirection,
        in identifiers: [ID]
    ) -> ID? {
        guard !identifiers.isEmpty else { return nil }
        guard let selectedID,
              let currentIndex = identifiers.firstIndex(of: selectedID) else {
            return identifiers.first
        }
        switch direction {
        case .previous:
            return identifiers[
                currentIndex == identifiers.startIndex
                    ? identifiers.index(before: identifiers.endIndex)
                    : identifiers.index(before: currentIndex)
            ]
        case .next:
            let nextIndex = identifiers.index(after: currentIndex)
            return identifiers[nextIndex == identifiers.endIndex ? identifiers.startIndex : nextIndex]
        }
    }
}

public enum DesktopThreadPanel: String, CaseIterable, Identifiable, Sendable {
    case conversation
    case plan
    case changes
    case terminal
    case preview
    case evidence
    case knowledge

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .conversation: "Chat"
        case .plan: "Plan"
        case .changes: "Changes"
        case .terminal: "Terminal"
        case .preview: "Preview"
        case .evidence: "Evidence"
        case .knowledge: "Knowledge"
        }
    }

    public var symbol: String {
        switch self {
        case .conversation: "bubble.left.and.bubble.right"
        case .plan: "list.bullet.clipboard"
        case .changes: "doc.on.doc"
        case .terminal: "terminal"
        case .preview: "safari"
        case .evidence: "checkmark.seal"
        case .knowledge: "books.vertical"
        }
    }

    public static func available(forCodingThread isCodingThread: Bool) -> [Self] {
        if isCodingThread {
            return [.conversation, .plan, .changes, .terminal, .preview, .evidence, .knowledge]
        }
        return [.conversation, .plan, .changes, .evidence]
    }
}

public enum DesktopCodingWorkflowStage: CaseIterable, Equatable, Sendable {
    case discuss
    case planning
    case planReview
    case preparing
    case implementing
    case implementationReview
    case evidenceReview
    case knowledgeReview
    case completed
    case rejected
    case failed
}

public struct DesktopCodingWorkflowPresentation: Equatable, Sendable {
    public static let workflowPath =
        "Discuss → Plan → Approve → Implement → Review changes → Review evidence → Update knowledge"

    public let stage: DesktopCodingWorkflowStage

    public init(stage: DesktopCodingWorkflowStage) {
        self.stage = stage
    }

    public var compactLabel: String {
        switch stage {
        case .discuss: "Discuss · 1/7"
        case .planning: "Planning · 2/7"
        case .planReview: "Plan approval · 3/7"
        case .preparing: "Preparing · 4/7"
        case .implementing: "Implementing · 4/7"
        case .implementationReview: "Review changes · 5/7"
        case .evidenceReview: "Review evidence · 6/7"
        case .knowledgeReview: "Knowledge update · 7/7"
        case .completed: "Completed"
        case .rejected: "Rejected"
        case .failed: "Stopped safely"
        }
    }

    public var progressLabel: String {
        switch stage {
        case .discuss: "Stage 1 of 7 · Discuss"
        case .planning: "Stage 2 of 7 · Plan"
        case .planReview: "Stage 3 of 7 · Approve"
        case .preparing, .implementing: "Stage 4 of 7 · Implement"
        case .implementationReview: "Stage 5 of 7 · Review changes"
        case .evidenceReview: "Stage 6 of 7 · Review evidence"
        case .knowledgeReview: "Stage 7 of 7 · Knowledge update"
        case .completed: "Complete · Knowledge reconciled or waived"
        case .rejected: "Stopped · Rejected"
        case .failed: "Stopped safely · No accepted result"
        }
    }

    public var title: String {
        switch stage {
        case .discuss: "Discuss the task"
        case .planning: "Planning read-only"
        case .planReview: "Plan needs your approval"
        case .preparing: "Preparing the isolated worktree"
        case .implementing: "Implementing in an isolated worktree"
        case .implementationReview: "Changes are ready for review"
        case .evidenceReview: "Evidence needs your review"
        case .knowledgeReview: "Knowledge update pending"
        case .completed: "Completed"
        case .rejected: "Rejected; isolated changes retained"
        case .failed: "Stopped safely"
        }
    }

    public var detail: String {
        switch stage {
        case .discuss:
            "Your next message starts a read-only planning turn. It cannot write code."
        case .planning:
            "No write authority or network access is available. The structured plan will appear in Plan."
        case .planReview:
            "Review or revise the plan. Implementation cannot start until you approve it in Plan."
        case .preparing:
            "Kaname is creating or checking the isolated worktree and signed evidence boundary."
        case .implementing:
            "One approved, network-denied turn may write only inside the linked worktree."
        case .implementationReview:
            "Inspect the isolated changes in Changes before starting independent checks."
        case .evidenceReview:
            "Provider completion is not acceptance. Inspect and decide in Evidence."
        case .knowledgeReview:
            "The code is accepted locally. Reconcile or waive the durable update in Knowledge."
        case .completed:
            "The knowledge update was reconciled or explicitly waived. Nothing was pushed, published, or merged."
        case .rejected:
            "The changes remain isolated and recoverable. Send revision guidance to request a fresh plan."
        case .failed:
            "No result was accepted. Inspect the error, then send a revised request or retry the planning turn."
        }
    }

    public var symbol: String {
        switch stage {
        case .failed, .rejected: "exclamationmark.shield.fill"
        case .planning, .preparing, .implementing: "hourglass"
        case .planReview, .implementationReview, .evidenceReview, .knowledgeReview:
            "hand.raised.fill"
        case .completed: "checkmark.seal.fill"
        case .discuss: "text.bubble"
        }
    }

    public var ownerPanel: DesktopThreadPanel? {
        switch stage {
        case .discuss: .conversation
        case .planning, .planReview: .plan
        case .preparing, .implementing, .implementationReview, .rejected: .changes
        case .evidenceReview: .evidence
        case .knowledgeReview: .knowledge
        case .completed, .failed: nil
        }
    }

    public var attentionPanel: DesktopThreadPanel? {
        switch stage {
        case .planReview: .plan
        case .implementationReview, .rejected: .changes
        case .evidenceReview: .evidence
        case .knowledgeReview: .knowledge
        case .discuss, .planning, .preparing, .implementing, .completed, .failed: nil
        }
    }

    public var requiresAttention: Bool { attentionPanel != nil }
}
