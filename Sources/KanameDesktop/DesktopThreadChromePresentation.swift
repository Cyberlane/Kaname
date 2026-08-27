import Foundation

public extension DesktopThreadPanel {
    var accessibilityIdentifier: String {
        "thread-panel-\(label.lowercased())"
    }

    static func available(isCoding: Bool) -> [Self] {
        available(forCodingThread: isCoding)
    }
}

public struct DesktopThreadPanelBadges: Equatable, Sendable {
    public static let maximumVisibleCount = 99

    private let counts: [DesktopThreadPanel: Int]

    public init(plan: Int = 0, changes: Int = 0, terminal: Int = 0, preview: Int = 0, evidence: Int = 0, knowledge: Int = 0) {
        counts = [
            .plan: plan,
            .changes: changes,
            .terminal: terminal,
            .preview: preview,
            .evidence: evidence,
            .knowledge: knowledge,
        ]
    }

    public func count(for panel: DesktopThreadPanel) -> Int? {
        guard panel != .conversation else { return nil }
        guard let rawCount = counts[panel], rawCount > 0 else { return nil }
        return min(rawCount, Self.maximumVisibleCount)
    }
}

public enum DesktopThreadChromeAccent: Equatable, Sendable {
    case calm
    case active
    case attention
    case success
    case failure
}

public enum DesktopCodingGateState: Equatable, Sendable {
    case complete
    case current
    case upcoming
    case stopped

    public var accessibilityLabel: String {
        switch self {
        case .complete: "Complete"
        case .current: "Current"
        case .upcoming: "Upcoming"
        case .stopped: "Stopped"
        }
    }
}

public enum DesktopCodingWorkflowAction: Equatable, Sendable {
    case none
    case approvePlan
    case reviewChanges
    case reviewEvidence
    case reviewKnowledge
}

public extension DesktopCodingWorkflowStage {
    static let workflowPath = "Discuss → Plan → Approve → Implement → Review changes → Review evidence → Update knowledge"
    static let gateLabels = ["Discuss", "Plan", "Approve", "Implement", "Changes", "Evidence", "Knowledge"]

    var action: DesktopCodingWorkflowAction {
        switch self {
        case .planReview: .approvePlan
        case .implementationReview: .reviewChanges
        case .evidenceReview: .reviewEvidence
        case .knowledgeReview: .reviewKnowledge
        case .discuss, .planning, .preparing, .implementing, .completed, .rejected, .failed: .none
        }
    }

    var needsExpandedPresentation: Bool {
        action != .none || self == .rejected || self == .failed
    }

    var compactStatus: String {
        switch self {
        case .discuss: "Discuss · next turn plans read-only"
        case .planning: "Planning safely · Read-only · Network off"
        case .planReview: "Plan ready · Your approval is required"
        case .preparing: "Preparing isolated worktree · Network off"
        case .implementing: "Implementing · Isolated worktree · Network off"
        case .implementationReview: "Implementation ready · Review changes"
        case .evidenceReview: "Checks ready · Accept or request changes"
        case .knowledgeReview: "Accepted locally · Review knowledge"
        case .completed: "Complete · Accepted locally · Nothing published"
        case .rejected: "Stopped · Isolated changes retained"
        case .failed: "Stopped safely · No result accepted"
        }
    }

    var title: String {
        switch self {
        case .discuss: "Discuss the task"
        case .planning: "Planning read-only"
        case .planReview: "Plan needs your approval"
        case .preparing: "Preparing the next guarded stage"
        case .implementing: "Implementing in an isolated worktree"
        case .implementationReview: "Review changes before checks"
        case .evidenceReview: "Evidence needs your review"
        case .knowledgeReview: "Accepted · knowledge update pending"
        case .completed: "Completed"
        case .rejected: "Rejected; isolated changes retained"
        case .failed: "Stopped safely"
        }
    }

    var detail: String {
        switch self {
        case .discuss: "Your next message starts a read-only planning turn. It cannot write code."
        case .planning: "No write authority or network access is available. The structured plan will appear in the Plan tab."
        case .planReview: "Review or revise the plan. Implementation cannot start until you explicitly approve it."
        case .preparing: "Kaname is creating or checking the isolated worktree and signed evidence boundary."
        case .implementing: "One approved, network-denied turn may write only inside the linked worktree."
        case .implementationReview: "Review the isolated changes and run independent checks before evidence acceptance."
        case .evidenceReview: "Provider completion is not acceptance. Inspect the diff and verification evidence, then accept or reject."
        case .knowledgeReview: "The code is accepted locally. Review the proposed knowledge edit or provide a reason for no durable update."
        case .completed: "The knowledge update was reconciled or explicitly waived. Nothing was pushed, published, or merged."
        case .rejected: "The changes remain isolated and recoverable. Send revision guidance to request a fresh plan."
        case .failed: "No result was accepted. Inspect the error, then send a revised request or retry the planning turn."
        }
    }

    var progressLabel: String {
        switch self {
        case .discuss: "Gate 1 of 7 · Discuss"
        case .planning: "Gate 2 of 7 · Plan"
        case .planReview: "Gate 3 of 7 · Approve plan"
        case .preparing, .implementing: "Gate 4 of 7 · Implement"
        case .implementationReview: "Gate 5 of 7 · Review changes"
        case .evidenceReview: "Gate 6 of 7 · Review evidence"
        case .knowledgeReview: "Gate 7 of 7 · Update knowledge"
        case .completed: "All 7 gates complete"
        case .rejected: "Workflow stopped · Rejected"
        case .failed: "Workflow stopped · No accepted result"
        }
    }

    var systemImage: String {
        switch self {
        case .failed, .rejected: "exclamationmark.shield.fill"
        case .planning, .preparing, .implementing: "hourglass"
        case .planReview, .implementationReview, .evidenceReview, .knowledgeReview:
            "person.crop.circle.badge.questionmark"
        case .completed: "checkmark.seal.fill"
        case .discuss: "text.bubble"
        }
    }

    var accent: DesktopThreadChromeAccent {
        switch self {
        case .failed, .rejected: .failure
        case .planReview, .implementationReview, .evidenceReview, .knowledgeReview: .attention
        case .planning, .preparing, .implementing: .active
        case .completed: .success
        case .discuss: .calm
        }
    }

    var activeGateIndex: Int {
        switch self {
        case .discuss: 0
        case .planning: 1
        case .planReview: 2
        case .preparing, .implementing: 3
        case .implementationReview: 4
        case .evidenceReview: 5
        case .knowledgeReview: 6
        case .completed: 7
        case .rejected, .failed: 0
        }
    }

    func gateState(at index: Int) -> DesktopCodingGateState {
        guard Self.gateLabels.indices.contains(index) else { return .upcoming }
        if self == .completed { return .complete }
        if self == .failed || self == .rejected {
            return index == min(activeGateIndex, Self.gateLabels.count - 1) ? .stopped : .upcoming
        }
        if index < activeGateIndex { return .complete }
        if index == activeGateIndex { return .current }
        return .upcoming
    }
}
