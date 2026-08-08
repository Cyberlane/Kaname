import SwiftUI
import KanameDomain

public enum Nord {
    public static let polarNight0 = Color(red: 46 / 255, green: 52 / 255, blue: 64 / 255)
    public static let polarNight1 = Color(red: 59 / 255, green: 66 / 255, blue: 82 / 255)
    public static let polarNight2 = Color(red: 67 / 255, green: 76 / 255, blue: 94 / 255)
    public static let polarNight3 = Color(red: 76 / 255, green: 86 / 255, blue: 106 / 255)
    public static let snowStorm0 = Color(red: 216 / 255, green: 222 / 255, blue: 233 / 255)
    public static let frost0 = Color(red: 143 / 255, green: 188 / 255, blue: 187 / 255)
    public static let frost1 = Color(red: 136 / 255, green: 192 / 255, blue: 208 / 255)
    public static let frost2 = Color(red: 129 / 255, green: 161 / 255, blue: 193 / 255)
    public static let frost3 = Color(red: 94 / 255, green: 129 / 255, blue: 172 / 255)
    public static let auroraRed = Color(red: 191 / 255, green: 97 / 255, blue: 106 / 255)
    public static let auroraOrange = Color(red: 208 / 255, green: 135 / 255, blue: 112 / 255)
    public static let auroraYellow = Color(red: 235 / 255, green: 203 / 255, blue: 139 / 255)
    public static let auroraGreen = Color(red: 163 / 255, green: 190 / 255, blue: 140 / 255)
    public static let auroraPurple = Color(red: 180 / 255, green: 142 / 255, blue: 173 / 255)
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
        switch self {
        case .none: "No attention needed"
        case .queued: "Queued"
        case .running: "Running"
        case .needsResponse: "Needs response"
        case .needsReview: "Needs review"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }

    var tint: Color {
        switch self {
        case .none: Nord.polarNight3
        case .queued: Nord.frost3
        case .running: Nord.frost0
        case .needsResponse, .needsReview: Nord.auroraYellow
        case .failed: Nord.auroraRed
        case .interrupted: Nord.auroraPurple
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
