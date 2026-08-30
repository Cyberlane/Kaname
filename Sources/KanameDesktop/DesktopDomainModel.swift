import Foundation

public enum DesktopRecordState: String, Codable, CaseIterable, Equatable, Sendable {
    case ready
    case draft
    case proposed
    case paused
    case disconnected
    case needsReview
    case waiting
    case running
    case failed

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .draft: "Draft"
        case .proposed: "Proposed"
        case .paused: "Paused"
        case .disconnected: "Disconnected"
        case .needsReview: "Needs review"
        case .waiting: "Waiting"
        case .running: "Running"
        case .failed: "Failed"
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
    /// Human-facing catalogue label. Runtime loading uses `registryName` only.
    public var name: String
    public var registryName: String? = nil
    public var kind: Kind
    public var scope: String
    public var source: String
    public var revision: String
    public var status: DesktopRecordState
    public var enabled: Bool
}

public struct DesktopAccountRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Service: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
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

    public init(
        id: String,
        service: Service,
        displayName: String,
        identity: String,
        status: DesktopRecordState,
        scope: String
    ) {
        (self.id, self.service, self.displayName, self.identity, self.status, self.scope) =
            (id, service, displayName, identity, status, scope)
    }
}

public struct DesktopCalendarSourceRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Equatable, Sendable {
        case google
        case apple

        public var label: String { rawValue.capitalized }
    }

    public let id: String
    public var accountID: String
    public var externalIdentifier: String
    public var provider: Provider
    public var displayName: String
    public var ownerIdentity: String
    public var accessLevel: String
    public var isPrimary: Bool
    public var isEnabled: Bool

    public static func connected(
        id: String,
        accountID: String,
        externalIdentifier: String,
        provider: Provider,
        displayName: String,
        ownerIdentity: String,
        accessLevel: String,
        isPrimary: Bool,
        isEnabled: Bool
    ) -> Self {
        Self(
            id: id,
            accountID: accountID,
            externalIdentifier: externalIdentifier,
            provider: provider,
            displayName: displayName,
            ownerIdentity: ownerIdentity,
            accessLevel: accessLevel,
            isPrimary: isPrimary,
            isEnabled: isEnabled
        )
    }
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
    public enum MutationKind: String, Codable, CaseIterable, Equatable, Sendable {
        case create
        case update
        case delete

        public var label: String { rawValue.capitalized }
    }

    public let id: String
    public var accountID: String?
    public var calendarSourceID: String?
    public var title: String
    public var startAtUnixMillis: Int64
    public var durationMinutes: Int
    public var timeZoneIdentifier: String
    public var recurrence: String
    public var isAllDay: Bool? = nil
    public var status: DesktopRecordState
    public var mutationKind: MutationKind? = nil
    public var eventExternalID: String? = nil
    public var seriesMasterExternalID: String? = nil
    public var eventRevision: String? = nil
    public var originalTitle: String? = nil
    public var originalStartAtUnixMillis: Int64? = nil
    public var originalEndAtUnixMillis: Int64? = nil
    public var originalTimeZoneIdentifier: String? = nil
    public var originalRecurrence: [String]? = nil
    public var originalIsAllDay: Bool? = nil
    public var seriesMasterRevision: String? = nil
    public var seriesMasterRecurrence: [String]? = nil
    public var seriesMasterStartAtUnixMillis: Int64? = nil
    public var recurrenceScope: String? = nil
    public var approvalID: String? = nil
    public var exactTarget: String? = nil
    public var remoteReceipt: String? = nil
    public var reconciledAtUnixMillis: Int64? = nil
    public var mutationPhase: String? = nil
}

public enum DesktopAutomationActionKind: String, Codable, CaseIterable, Equatable, Sendable {
    case notification
    case conversation
    case skill

    public var label: String {
        switch self {
        case .notification: "Local notification"
        case .conversation: "Start agent conversation"
        case .skill: "Skill-guided read-only conversation"
        }
    }
}

public enum DesktopAutomationAuthority: String, Codable, CaseIterable, Equatable, Sendable {
    case localOnly
    case askEveryRun
    case standing

    public var label: String {
        switch self {
        case .localOnly: "Local-only action"
        case .askEveryRun: "Ask before every run"
        case .standing: "Visible standing authority"
        }
    }
}

public struct DesktopScheduleSpec: Codable, Equatable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Equatable, Sendable {
        case once
        case daily
        case weekly

        public var label: String { rawValue.capitalized }
    }

    public var frequency: Frequency
    public var hour: Int
    public var minute: Int
    public var weekday: Int?
    public var onceAtUnixMillis: Int64?

    public static func anchored(
        frequency: Frequency,
        hour: Int,
        minute: Int,
        weekday: Int? = nil,
        onceAtUnixMillis: Int64? = nil
    ) -> Self {
        Self(frequency: frequency, hour: hour, minute: minute, weekday: weekday, onceAtUnixMillis: onceAtUnixMillis)
    }
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
    public var createdAtUnixMillis: Int64?
    public var scheduleSpec: DesktopScheduleSpec? = nil
    public var actionKind: DesktopAutomationActionKind? = nil
    public var authority: DesktopAutomationAuthority? = nil
    public var projectID: String? = nil
    public var skillIDs: [String]? = nil
    public var toolNames: [String]? = nil
    public var notificationEnabled: Bool? = nil
    public var standingAuthorityApprovedAtUnixMillis: Int64? = nil
    public var standingAuthorityApprovalID: String? = nil
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
    public var calendarSources: [DesktopCalendarSourceRecord]
    public var emailDrafts: [DesktopEmailDraft]
    public var calendarProposals: [DesktopCalendarProposal]
    public var automations: [DesktopAutomationRule]
    public var gitWorkspaces: [DesktopGitWorkspace]

    public init(
        research: [DesktopResearchRecord],
        knowledgeSources: [DesktopKnowledgeSource],
        skills: [DesktopSkillRecord],
        accounts: [DesktopAccountRecord],
        calendarSources: [DesktopCalendarSourceRecord],
        emailDrafts: [DesktopEmailDraft],
        calendarProposals: [DesktopCalendarProposal],
        automations: [DesktopAutomationRule],
        gitWorkspaces: [DesktopGitWorkspace]
    ) {
        (self.research, self.knowledgeSources, self.skills) = (research, knowledgeSources, skills)
        (self.accounts, self.calendarSources, self.emailDrafts) = (accounts, calendarSources, emailDrafts)
        (self.calendarProposals, self.automations, self.gitWorkspaces) = (calendarProposals, automations, gitWorkspaces)
    }

    public static let empty = DesktopDomainSnapshot(
        research: [],
        knowledgeSources: [],
        skills: [],
        accounts: [],
        calendarSources: [],
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
                    status: .needsReview,
                    lastReadAtUnixMillis: nil
                ),
                DesktopKnowledgeSource(
                    id: "knowledge-kaname-repository",
                    name: "Kaname repository",
                    kind: .repository,
                    scope: "Selected project files and instructions",
                    status: .needsReview,
                    lastReadAtUnixMillis: nil
                ),
            ],
            skills: [
                DesktopSkillRecord(
                    id: "skill-mori-review",
                    name: "Mori structural review",
                    registryName: "mori-review-similarity",
                    kind: .hook,
                    scope: "Kaname repository",
                    source: "Cyberlane/mori",
                    revision: "Pinned by .mori-version",
                    status: .needsReview,
                    enabled: true
                ),
                DesktopSkillRecord(
                    id: "skill-obsidian",
                    name: "Obsidian knowledge",
                    registryName: "obsidian-cli",
                    kind: .skill,
                    scope: "Explicit vault paths",
                    source: "Local skill catalogue",
                    revision: "Managed locally",
                    status: .needsReview,
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
            calendarSources: [],
            emailDrafts: [],
            calendarProposals: [],
            automations: [],
            gitWorkspaces: []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case research
        case knowledgeSources
        case skills
        case accounts
        case calendarSources
        case emailDrafts
        case calendarProposals
        case automations
        case gitWorkspaces
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var skills = try container.decode([DesktopSkillRecord].self, forKey: .skills)
        for index in skills.indices where skills[index].registryName == nil {
            skills[index].registryName = switch skills[index].id {
            case "skill-mori-review": "mori-review-similarity"
            case "skill-obsidian": "obsidian-cli"
            default: nil
            }
        }
        self.init(
            research: try container.decode([DesktopResearchRecord].self, forKey: .research),
            knowledgeSources: try container.decode([DesktopKnowledgeSource].self, forKey: .knowledgeSources),
            skills: skills,
            accounts: try container.decode([DesktopAccountRecord].self, forKey: .accounts),
            calendarSources: try container.decodeIfPresent([DesktopCalendarSourceRecord].self, forKey: .calendarSources) ?? [],
            emailDrafts: try container.decode([DesktopEmailDraft].self, forKey: .emailDrafts),
            calendarProposals: try container.decode([DesktopCalendarProposal].self, forKey: .calendarProposals),
            automations: try container.decode([DesktopAutomationRule].self, forKey: .automations),
            gitWorkspaces: try container.decode([DesktopGitWorkspace].self, forKey: .gitWorkspaces)
        )
    }
}

public struct DesktopTimeZonePresentation: Equatable, Sendable {
    public let anchored: String
    public let viewerLocal: String
    public let anchoredTimeZoneIdentifier: String
    public let viewerTimeZoneIdentifier: String
    public let differsFromViewer: Bool
}

public enum DesktopTimeZonePresenter {
    public static func presentation(
        for date: Date,
        anchoredTimeZoneIdentifier: String,
        viewerTimeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> DesktopTimeZonePresentation? {
        guard let anchoredTimeZone = TimeZone(identifier: anchoredTimeZoneIdentifier) else { return nil }
        return DesktopTimeZonePresentation(
            anchored: formatted(date, timeZone: anchoredTimeZone, locale: locale),
            viewerLocal: formatted(date, timeZone: viewerTimeZone, locale: locale),
            anchoredTimeZoneIdentifier: anchoredTimeZone.identifier,
            viewerTimeZoneIdentifier: viewerTimeZone.identifier,
            differsFromViewer: anchoredTimeZone.identifier != viewerTimeZone.identifier
        )
    }

    private static func formatted(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
