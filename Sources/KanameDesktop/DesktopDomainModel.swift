import Foundation

public enum DesktopRecordState: String, Codable, CaseIterable, Equatable, Sendable {
    case ready
    case draft
    case proposed
    case paused
    case disconnected
    case needsReview

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .draft: "Draft"
        case .proposed: "Proposed"
        case .paused: "Paused"
        case .disconnected: "Disconnected"
        case .needsReview: "Needs review"
        }
    }
}

public struct DesktopResearchRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var question: String
    public var status: DesktopRecordState
    public var sourceCount: Int
    public var updatedAtUnixMillis: Int64
}

public struct DesktopKnowledgeSource: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Equatable, Sendable {
        case obsidian
        case lode
        case repository

        public var label: String { rawValue.capitalized }
    }

    public let id: String
    public var name: String
    public var kind: Kind
    public var scope: String
    public var status: DesktopRecordState
    public var lastReadAtUnixMillis: Int64?
}

public struct DesktopSkillRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Equatable, Sendable {
        case skill
        case tool
        case connector
        case hook

        public var label: String { rawValue.capitalized }
    }

    public let id: String
    public var name: String
    public var kind: Kind
    public var scope: String
    public var source: String
    public var revision: String
    public var status: DesktopRecordState
    public var enabled: Bool
}

public struct DesktopAccountRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Service: String, Codable, CaseIterable, Equatable, Sendable {
        case github
        case gmail
        case googleCalendar
        case appleCalendar

        public var label: String {
            switch self {
            case .github: "GitHub"
            case .gmail: "Gmail"
            case .googleCalendar: "Google Calendar"
            case .appleCalendar: "Apple Calendar"
            }
        }
    }

    public let id: String
    public var service: Service
    public var displayName: String
    public var identity: String
    public var status: DesktopRecordState
    public var scope: String
}

public struct DesktopEmailDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var accountID: String?
    public var recipients: String
    public var subject: String
    public var body: String
    public var status: DesktopRecordState
    public var updatedAtUnixMillis: Int64
}

public struct DesktopCalendarProposal: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var accountID: String?
    public var title: String
    public var startAtUnixMillis: Int64
    public var durationMinutes: Int
    public var timeZoneIdentifier: String
    public var recurrence: String
    public var status: DesktopRecordState
}

public struct DesktopAutomationRule: Codable, Equatable, Identifiable, Sendable {
    public enum MissedRunPolicy: String, Codable, CaseIterable, Equatable, Sendable {
        case skip
        case ask

        public var label: String {
            switch self {
            case .skip: "Skip missed runs"
            case .ask: "Ask before catch-up"
            }
        }
    }

    public let id: String
    public var name: String
    public var schedule: String
    public var timeZoneIdentifier: String
    public var actionSummary: String
    public var missedRunPolicy: MissedRunPolicy
    public var status: DesktopRecordState
    public var nextRunAtUnixMillis: Int64?
    public var lastResult: String
}

public struct DesktopGitWorkspace: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var projectID: String?
    public var name: String
    public var localPath: String
    public var branch: String
    public var remoteSummary: String
    public var status: DesktopRecordState
}

public struct DesktopDomainSnapshot: Codable, Equatable, Sendable {
    public var research: [DesktopResearchRecord]
    public var knowledgeSources: [DesktopKnowledgeSource]
    public var skills: [DesktopSkillRecord]
    public var accounts: [DesktopAccountRecord]
    public var emailDrafts: [DesktopEmailDraft]
    public var calendarProposals: [DesktopCalendarProposal]
    public var automations: [DesktopAutomationRule]
    public var gitWorkspaces: [DesktopGitWorkspace]

    public static let empty = DesktopDomainSnapshot(
        research: [],
        knowledgeSources: [],
        skills: [],
        accounts: [],
        emailDrafts: [],
        calendarProposals: [],
        automations: [],
        gitWorkspaces: []
    )

    public static func starter(now: Int64) -> DesktopDomainSnapshot {
        DesktopDomainSnapshot(
            research: [],
            knowledgeSources: [
                DesktopKnowledgeSource(
                    id: "knowledge-coding-ade",
                    name: "Coding ADE",
                    kind: .obsidian,
                    scope: "Projects/Coding ADE/Overview.md",
                    status: .ready,
                    lastReadAtUnixMillis: now
                ),
                DesktopKnowledgeSource(
                    id: "knowledge-kaname-repository",
                    name: "Kaname repository",
                    kind: .repository,
                    scope: "Selected project files and instructions",
                    status: .ready,
                    lastReadAtUnixMillis: now
                ),
            ],
            skills: [
                DesktopSkillRecord(
                    id: "skill-mori-review",
                    name: "Mori structural review",
                    kind: .hook,
                    scope: "Kaname repository",
                    source: "Cyberlane/mori",
                    revision: "Pinned by .mori-version",
                    status: .ready,
                    enabled: true
                ),
                DesktopSkillRecord(
                    id: "skill-obsidian",
                    name: "Obsidian knowledge",
                    kind: .skill,
                    scope: "Explicit vault paths",
                    source: "Local skill catalogue",
                    revision: "Managed locally",
                    status: .ready,
                    enabled: true
                ),
            ],
            accounts: [
                DesktopAccountRecord(
                    id: "account-github-unconfigured",
                    service: .github,
                    displayName: "GitHub",
                    identity: "No account connected",
                    status: .disconnected,
                    scope: "Read and write scopes not granted"
                ),
                DesktopAccountRecord(
                    id: "account-gmail-unconfigured",
                    service: .gmail,
                    displayName: "Gmail",
                    identity: "No account connected",
                    status: .disconnected,
                    scope: "Account isolation pending setup"
                ),
                DesktopAccountRecord(
                    id: "account-google-calendar-unconfigured",
                    service: .googleCalendar,
                    displayName: "Google Calendar",
                    identity: "No account connected",
                    status: .disconnected,
                    scope: "Calendar sources not granted"
                ),
                DesktopAccountRecord(
                    id: "account-apple-calendar-unconfigured",
                    service: .appleCalendar,
                    displayName: "Apple Calendar",
                    identity: "No calendar access",
                    status: .disconnected,
                    scope: "EventKit permission not requested"
                ),
            ],
            emailDrafts: [],
            calendarProposals: [],
            automations: [],
            gitWorkspaces: [
                DesktopGitWorkspace(
                    id: "git-kaname-local",
                    projectID: "project-kaname",
                    name: "Kaname",
                    localPath: "/Users/justinnel/Projects/coding-ade",
                    branch: "main",
                    remoteSummary: "Local inspection only",
                    status: .ready
                ),
            ]
        )
    }
}
