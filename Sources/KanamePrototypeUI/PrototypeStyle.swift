import SwiftUI
import KanameDomain
import KanameDesignSystem

/// Compatibility alias while existing Kaname screens migrate from primitive
/// Nord colors to semantic design-system roles.
public typealias Nord = KanameDesignSystem.Nord

private func attentionDisplayName(_ state: AttentionState) -> String {
    switch state {
    case .none: "No attention needed"
    case .queued: "Queued"
    case .running: "Running"
    case .needsResponse: "Needs response"
    case .needsReview: "Needs review"
    case .failed: "Failed"
    case .interrupted: "Interrupted"
    }
}

public extension AttentionState {
    static let dashboardOrder: [AttentionState] = [
        .needsResponse,
        .needsReview,
        .running,
        .queued,
        .failed,
        .interrupted,
    ]

    var displayName: String {
        attentionDisplayName(self)
    }

    var tint: Color {
        switch self {
        case .none: KanameColor.separator
        case .queued: KanameColor.accentStrong
        case .running: KanameColor.active
        case .needsResponse, .needsReview: KanameColor.warning
        case .failed: KanameColor.danger
        case .interrupted: KanameColor.blocked
        }
    }
}

public extension ApprovalAction {
    var displayName: String {
        switch self {
        case .codeChange: "Code change"
        case .sendEmail: "Send email"
        case .modifyCalendar: "Modify calendar"
        }
    }

    var egressDescription: String {
        switch self {
        case .codeChange: "No external transmission; writes remain in the selected isolated workspace."
        case .sendEmail: "The proposed message and recipient would leave the Mac through the selected Gmail account."
        case .modifyCalendar: "The requested event change would leave the Mac through the selected calendar account."
        }
    }

    var alternativeDescription: String {
        switch self {
        case .codeChange: "Keep the work as a proposed diff without modifying the workspace."
        case .sendEmail: "Save a draft or reject the send without contacting the recipient."
        case .modifyCalendar: "Keep the event unchanged or revise the proposed time."
        }
    }
}

public extension ApprovalStatus {
    var displayName: String {
        rawValue.capitalized
    }
}

public extension WorkspaceKind {
    var displayName: String {
        switch self {
        case .coding: "Coding"
        case .research: "Research"
        case .knowledge: "Knowledge"
        case .email: "Email"
        case .calendar: "Calendar"
        }
    }

    var symbolName: String {
        switch self {
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .research: "magnifyingglass"
        case .knowledge: "book.closed"
        case .email: "envelope"
        case .calendar: "calendar"
        }
    }
}
