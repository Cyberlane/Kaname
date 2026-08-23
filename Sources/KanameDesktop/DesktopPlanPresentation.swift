import Foundation

public enum DesktopPlanPhase: Equatable, Sendable {
    case notStarted
    case saved
    case drafting
    case awaitingApproval
    case implementing
    case reviewingResult
    case completed
    case stopped

    public var label: String {
        switch self {
        case .notStarted: "No plan requested"
        case .saved: "Saved plan"
        case .drafting: "Planning read-only"
        case .awaitingApproval: "Awaiting your review"
        case .implementing: "Implementation in progress"
        case .reviewingResult: "Implementation ready for review"
        case .completed: "Plan completed"
        case .stopped: "Stopped safely"
        }
    }

    public var detail: String {
        switch self {
        case .notStarted:
            "Request a plan in Chat. Planning cannot write code."
        case .saved:
            "This plan is preserved for reference and has no active implementation authority."
        case .drafting:
            "The provider is preparing these steps without write authority or network access."
        case .awaitingApproval:
            "Review every step. Implementation remains blocked until you explicitly approve this exact plan."
        case .implementing:
            "The approved work is running once, with network denied, inside an isolated worktree."
        case .reviewingResult:
            "Review the resulting changes and independent evidence in their dedicated tabs."
        case .completed:
            "The implementation was accepted locally; no push, publish, or merge happened automatically."
        case .stopped:
            "No result was accepted. Any isolated work remains recoverable where available."
        }
    }

    public var symbol: String {
        switch self {
        case .notStarted: "list.bullet.clipboard"
        case .saved: "archivebox"
        case .drafting: "hourglass"
        case .awaitingApproval: "person.crop.circle.badge.questionmark"
        case .implementing: "hammer.fill"
        case .reviewingResult: "doc.text.magnifyingglass"
        case .completed: "checkmark.seal.fill"
        case .stopped: "exclamationmark.shield.fill"
        }
    }
}

public extension DesktopPlanItem.State {
    var planStatusLabel: String {
        switch self {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .complete: "Complete"
        }
    }

    var planStatusSymbol: String {
        switch self {
        case .pending: "circle"
        case .inProgress: "circle.dotted"
        case .complete: "checkmark.circle.fill"
        }
    }
}

public struct DesktopPlanPresentation: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: String
        public let ordinal: Int
        public let totalCount: Int
        public let title: String
        public let state: DesktopPlanItem.State
        public let statusLabel: String
        public let statusSymbol: String

        public var isCurrent: Bool { state == .inProgress }

        public var accessibilityLabel: String {
            "Step \(ordinal) of \(totalCount): \(title). Status: \(statusLabel)."
        }
    }

    public let phase: DesktopPlanPhase
    public let rows: [Row]

    public init(items: [DesktopPlanItem], phase: DesktopPlanPhase) {
        self.phase = phase
        rows = items.enumerated().map { index, item in
            Row(
                id: item.id,
                ordinal: index + 1,
                totalCount: items.count,
                title: item.title,
                state: item.state,
                statusLabel: Self.statusLabel(for: item.state, phase: phase),
                statusSymbol: item.state.planStatusSymbol
            )
        }
    }

    public var stepCountLabel: String {
        rows.count == 1 ? "1 step" : "\(rows.count) steps"
    }

    public var progressLabel: String {
        let completedCount = rows.lazy.filter { $0.state == .complete }.count
        guard !rows.isEmpty, completedCount > 0 else { return stepCountLabel }
        return "\(completedCount) of \(rows.count) complete"
    }

    public var accessibilityLabel: String {
        "Implementation plan. \(phase.label). \(progressLabel)."
    }

    private static func statusLabel(for state: DesktopPlanItem.State, phase: DesktopPlanPhase) -> String {
        if state == .pending && (phase == .drafting || phase == .awaitingApproval) {
            return "Planned"
        }
        return state.planStatusLabel
    }
}
