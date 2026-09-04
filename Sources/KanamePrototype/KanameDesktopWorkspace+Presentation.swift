import KanameDesktop
import KanameDesktopUI
import KanameDesignSystem
import KanameWorkflowHost
import KanameConnectivity
import KanameDomain
import KanamePrototypeUI
import KanameLocalCore
import KanameLinkHost
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

extension DesktopDestination {
    var contextDetail: String {
        switch self {
        case .home: "Attention, active work, project boundaries, and system health."
        case .threads: "Conversation continuity over durable local records."
        case .inbox: "Rule-based attention projection over those same threads."
        case .projects: "Deliberate repository, instruction, skill, and knowledge boundaries."
        case .research: "Questions, source boundaries, citations, and reusable findings."
        case .knowledge: "Private Obsidian context and repository knowledge with visible provenance."
        case .email: "Account-isolated drafts and externally reconciled communication."
        case .calendar: "Source-aware event proposals with time zones and consequence review."
        case .automations: "Workflow design, runs, components, readiness, schedules, and durable evidence."
        case .github: "Local and remote repository state, checks, reviews, and stack relationships."
        case .skills: "Capability provenance, scope, permissions, compatibility, and updates."
        case .devices: "Encrypted reachability and recovery without silently widening authority."
        case .links: "Explicitly published collaboration with external principals who never inherit device authority."
        case .liveCodex: "Isolated worktree inspection, planning, explicit write approval, and evidence review."
        case .localCore: "Provider-free replay, failure, and recovery evidence from the durable authority."
        case .settings: "Presentation and privacy defaults that never grant external authority."
        }
    }
}

private extension DesktopRecordState {
    var accessibilitySymbol: String {
        switch self {
        case .ready: "checkmark.circle"
        case .draft: "pencil.circle"
        case .proposed: "lightbulb"
        case .paused: "pause.circle"
        case .disconnected: "bolt.slash"
        case .needsReview: "eye.circle"
        case .waiting: "clock"
        case .running: "progress.indicator"
        case .failed: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .ready: KanameColor.success
        case .draft: KanameColor.accent
        case .proposed: KanameColor.blocked
        case .paused: KanameColor.warning
        case .disconnected: KanameColor.separator
        case .needsReview: KanameColor.external
        case .waiting: KanameColor.warning
        case .running: KanameColor.accent
        case .failed: KanameColor.danger
        }
    }

    var foreground: Color {
        self == .disconnected ? .secondary : tint
    }
}

extension DesktopActionState {
    var accessibilitySymbol: String {
        switch self {
        case .proposed: "lightbulb"
        case .awaitingApproval: "checkmark.shield"
        case .approved: "hand.thumbsup"
        case .rejected: "hand.thumbsdown"
        case .running: "progress.indicator"
        case .completed, .reconciled: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .interrupted: "stop.circle"
        case .cancelled: "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .proposed, .awaitingApproval: KanameColor.warning
        case .approved, .running: KanameColor.accent
        case .rejected, .failed: KanameColor.danger
        case .interrupted: KanameColor.external
        case .completed, .reconciled: KanameColor.success
        case .cancelled: KanameColor.separator
        }
    }
}

private extension DesktopAttention {
    var accessibilitySymbol: String {
        switch self {
        case .needsResponse: "bubble.left"
        case .needsApproval: "checkmark.shield"
        case .needsInput: "questionmark.bubble"
        case .running: "progress.indicator"
        case .queued: "clock"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .archived: "archivebox"
        }
    }
}

extension DesktopKnowledgeSource.Kind {
    var symbol: String {
        switch self {
        case .obsidian: "diamond.fill"
        case .lode: "shippingbox.fill"
        case .repository: "folder.fill.badge.gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .obsidian: KanameColor.blocked
        case .lode: KanameColor.active
        case .repository: KanameColor.accent
        }
    }
}

extension DesktopSkillRecord.Kind {
    var symbol: String {
        switch self {
        case .skill: "wand.and.stars"
        case .tool: "hammer.fill"
        case .connector: "cable.connector"
        case .hook: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

extension DesktopArtifactRecord.Kind {
    var symbol: String {
        switch self {
        case .file: "doc.fill"
        case .diff: "plus.forwardslash.minus"
        case .report: "doc.text.fill"
        case .image: "photo.fill"
        case .log: "list.bullet.rectangle.fill"
        }
    }
}

extension DesktopAccountRecord.Service {
    var symbol: String {
        switch self {
        case .github: "point.3.connected.trianglepath.dotted"
        case .gmail: "envelope.fill"
        case .googleCalendar: "calendar.badge.clock"
        case .appleCalendar: "calendar"
        }
    }
}

extension DesktopAttention {
    var tint: Color {
        switch self {
        case .needsResponse, .needsApproval: KanameColor.warning
        case .needsInput: KanameColor.blocked
        case .running: KanameColor.active
        case .queued: KanameColor.accentStrong
        case .completed: KanameColor.success
        case .failed: KanameColor.danger
        case .archived: KanameColor.separator
        }
    }
}

extension DesktopWorkKind {
    var symbol: String {
        switch self {
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .research: "text.magnifyingglass"
        case .planning: "list.bullet.clipboard"
        case .personal: "person.fill"
        }
    }

    var startDetail: String {
        switch self {
        case .coding: "Discuss, plan, implement, and review work for a repository or workspace."
        case .research: "Investigate a question with explicit source and sensitivity boundaries."
        case .planning: "Shape a decision or implementation plan before granting write authority."
        case .personal: "Start non-coding work while keeping unrelated contexts separate."
        }
    }
}

extension DesktopMessageRole {
    var label: String {
        switch self {
        case .user: "You"
        case .assistant: "Kaname"
        case .system: "Local state"
        }
    }

    var background: Color {
        switch self {
        case .user: KanameColor.accentStrong.opacity(0.24)
        case .assistant: KanameColor.surface
        case .system: KanameColor.blocked.opacity(0.12)
        }
    }
}

extension DesktopPlanItem.State {
    var label: String {
        planStatusLabel
    }

    var symbol: String {
        planStatusSymbol
    }

    var tint: Color {
        switch self {
        case .pending: KanameColor.textPrimary.opacity(0.78)
        case .inProgress: KanameColor.accent
        case .complete: KanameColor.success
        }
    }
}

extension DesktopCodingWorkflowStage {
    func planPhase(hasSavedPlan: Bool) -> DesktopPlanPhase {
        switch self {
        case .discuss: hasSavedPlan ? .saved : .notStarted
        case .planning: .drafting
        case .planReview: .awaitingApproval
        case .preparing, .implementing: .implementing
        case .implementationReview, .evidenceReview, .knowledgeReview: .reviewingResult
        case .completed: .completed
        case .rejected, .failed: .stopped
        }
    }

    var tint: Color {
        switch self {
        case .failed, .rejected: KanameColor.danger
        case .planReview, .implementationReview, .evidenceReview, .knowledgeReview: KanameColor.warning
        case .planning, .preparing, .implementing: KanameColor.accent
        case .completed: KanameColor.success
        case .discuss: KanameColor.active
        }
    }
}

extension DesktopPlanPhase {
    var tint: Color {
        switch self {
        case .notStarted: Color.secondary
        case .saved: KanameColor.active
        case .drafting, .implementing: KanameColor.accent
        case .awaitingApproval, .reviewingResult: KanameColor.warning
        case .completed: KanameColor.success
        case .stopped: KanameColor.danger
        }
    }
}

extension DesktopPlanPresentation.Row {
    var tint: Color {
        state.tint
    }
}

extension DesktopEvidence.State {
    var label: String {
        switch self {
        case .passed: "Passed"
        case .pending: "Pending"
        case .notRun: "Not run"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .passed: "checkmark.seal.fill"
        case .pending: "clock.fill"
        case .notRun: "minus.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .passed: KanameColor.success
        case .pending: KanameColor.accent
        case .notRun: KanameColor.warning
        case .failed: KanameColor.danger
        }
    }
}

extension DesktopRemoteEvent.State {
    var label: String {
        switch self {
        case .passed: "Passed"
        case .ready: "Ready"
        case .notRun: "Not run"
        case .deferred: "Deferred"
        }
    }

    var symbol: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .ready: "circle.dotted"
        case .notRun: "minus.circle.fill"
        case .deferred: "pause.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .passed: KanameColor.success
        case .ready: KanameColor.accent
        case .notRun: KanameColor.warning
        case .deferred: KanameColor.warning
        }
    }
}
