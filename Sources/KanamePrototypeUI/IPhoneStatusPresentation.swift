import KanameDesignSystem

protocol IPhoneStatusSemantic: RawRepresentable where RawValue == String {
    var tone: KanameStatusTone { get }
    var symbolName: String { get }
    var accessibilityPrefix: String { get }
}

extension IPhoneStatusSemantic {
    var accessibilityPrefix: String { "Status" }

    var presentation: KanameStatusPresentation {
        KanameStatusPresentation(
            label: rawValue,
            tone: tone,
            symbolName: symbolName,
            accessibilityLabel: "\(accessibilityPrefix): \(rawValue)"
        )
    }

    static func presentation(for wireValue: String) -> KanameStatusPresentation {
        guard let semantic = Self(rawValue: wireValue) else {
            return KanameStatusPresentation(
                label: wireValue,
                tone: .neutral,
                symbolName: "questionmark.circle",
                accessibilityLabel: "Status: \(wireValue)"
            )
        }
        return semantic.presentation
    }
}

enum IPhoneDeliveryStatus: String, CaseIterable, Sendable, IPhoneStatusSemantic {
    case active = "Active"
    case ready = "Ready"
    case needsDecision = "Needs decision"
    case research = "Research"
    case paused = "Paused"

    var tone: KanameStatusTone {
        switch self {
        case .active, .research: .active
        case .ready: .success
        case .needsDecision: .attention
        case .paused: .neutral
        }
    }

    var symbolName: String {
        switch self {
        case .active: "waveform.path.ecg"
        case .ready: "checkmark.circle.fill"
        case .needsDecision: "checkmark.shield"
        case .research: "text.magnifyingglass"
        case .paused: "pause.circle"
        }
    }
}

enum IPhoneCheckStatus: String, CaseIterable, Sendable, IPhoneStatusSemantic {
    case passed = "Passed"
    case oneFailed = "1 failed"
    case fourChecksPassed = "4 checks passed"
    case allChecksPassed = "All checks passed"
    case lastRunPassed = "Last run passed"
    case planningBoundary = "Planning boundary"
    case gateReview = "Gate review"

    var tone: KanameStatusTone {
        switch self {
        case .passed, .fourChecksPassed, .allChecksPassed, .lastRunPassed: .success
        case .oneFailed: .danger
        case .planningBoundary: .informational
        case .gateReview: .attention
        }
    }

    var symbolName: String {
        switch self {
        case .passed, .fourChecksPassed, .allChecksPassed, .lastRunPassed: "checkmark.circle.fill"
        case .oneFailed: "xmark.octagon.fill"
        case .planningBoundary: "info.circle.fill"
        case .gateReview: "eye.circle"
        }
    }
}

enum IPhoneSessionStatus: String, CaseIterable, Sendable, IPhoneStatusSemantic {
    case running = "Running"
    case needsStart = "Needs start"
    case paused = "Paused"
    case ready = "Ready"
    case active = "Active"
    case manual = "Manual"
    case scheduled = "Scheduled"
    case protected = "Protected"
    case fixture = "Fixture"
    case enabled = "Enabled"

    var tone: KanameStatusTone {
        switch self {
        case .running, .active, .scheduled: .active
        case .needsStart, .protected: .attention
        case .ready, .enabled: .success
        case .paused, .manual: .neutral
        case .fixture: .external
        }
    }

    var symbolName: String {
        switch self {
        case .running: "waveform.path.ecg"
        case .needsStart: "play.circle"
        case .paused: "pause.circle"
        case .ready: "checkmark.circle.fill"
        case .active: "bolt.circle.fill"
        case .manual: "hand.tap"
        case .scheduled: "calendar.badge.clock"
        case .protected: "checkmark.shield"
        case .fixture: "sparkles.rectangle.stack"
        case .enabled: "checkmark.circle"
        }
    }
}

enum IPhoneCIStatus: String, CaseIterable, Sendable, IPhoneStatusSemantic {
    case oneFailure = "1 failure"
    case healthy = "Healthy"
    case noRun = "No run"
    case notApplicable = "Not applicable"

    var tone: KanameStatusTone {
        switch self {
        case .oneFailure: .danger
        case .healthy: .success
        case .noRun, .notApplicable: .neutral
        }
    }

    var symbolName: String {
        switch self {
        case .oneFailure: "xmark.octagon.fill"
        case .healthy: "checkmark.circle.fill"
        case .noRun: "circle"
        case .notApplicable: "minus.circle"
        }
    }
}

enum IPhoneRetryStatus: String, CaseIterable, Sendable, IPhoneStatusSemantic {
    case noRetryNeeded = "No retry needed"
    case retryNeedsApproval = "Retry needs approval"

    var tone: KanameStatusTone {
        switch self {
        case .noRetryNeeded: .success
        case .retryNeedsApproval: .attention
        }
    }

    var symbolName: String {
        switch self {
        case .noRetryNeeded: "checkmark.circle.fill"
        case .retryNeedsApproval: "checkmark.shield"
        }
    }

    var accessibilityPrefix: String {
        switch self {
        case .noRetryNeeded: "Status"
        case .retryNeedsApproval: "Approval required"
        }
    }
}

struct IPhoneMetadataPresentation: Equatable, Sendable {
    let label: String
    let symbolName: String
    let accessibilityLabel: String
}

enum IPhoneMetadataKind: String, CaseIterable, Sendable {
    case changedFiles
    case sessions
    case logs
    case workflow

    var symbolName: String {
        switch self {
        case .changedFiles: "doc.on.doc"
        case .sessions: "cpu"
        case .logs: "doc.text"
        case .workflow: "arrow.triangle.branch"
        }
    }

    func presentation(label: String) -> IPhoneMetadataPresentation {
        let accessibilityLabel = switch self {
        case .changedFiles: "Changed files: \(label)"
        case .sessions: "Sessions: \(label)"
        case .logs, .workflow: label
        }
        return IPhoneMetadataPresentation(
            label: label,
            symbolName: symbolName,
            accessibilityLabel: accessibilityLabel
        )
    }
}
