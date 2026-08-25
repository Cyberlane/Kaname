import Foundation
import KanameDesktop

enum DesktopDesignCaptureScenario: String, CaseIterable {
    case linkHost = "desktop-link-host"
    case homeStatuses = "desktop-home-statuses"
    case homeStatusesLargeText = "desktop-home-statuses-large-text"
    case githubStatuses = "desktop-github-statuses"
    case linkPublicationStatuses = "desktop-link-publication-statuses"

    var destination: String {
        switch self {
        case .linkHost, .linkPublicationStatuses: "links"
        case .homeStatuses, .homeStatusesLargeText: "home"
        case .githubStatuses: "github"
        }
    }

    var usesLargeText: Bool { self == .homeStatusesLargeText }
    var differentiatesWithoutColor: Bool { self == .homeStatuses }
    var usesSyntheticLink: Bool { self == .linkHost || self == .linkPublicationStatuses }
}

struct DesktopDesignCaptureConfiguration {
    let scenario: DesktopDesignCaptureScenario
    let locale: Locale
    let reduceMotion: Bool

    static func resolve(arguments: [String]) -> Self? {
        guard let flagIndex = arguments.firstIndex(of: "--desktop-design-scenario") else { return nil }
        guard arguments.indices.contains(flagIndex + 1),
              let scenario = DesktopDesignCaptureScenario(rawValue: arguments[flagIndex + 1]) else {
            preconditionFailure("--desktop-design-scenario requires a supported synthetic scenario ID")
        }
        return Self(scenario: scenario, locale: Locale(identifier: "en_US"), reduceMotion: false)
    }

    @MainActor
    func seed(_ model: DesktopAppModel) {
        model.setAttention(threadID: "thread-desktop-dogfood", attention: .needsResponse)
        model.setAttention(threadID: "thread-phase3-mobile", attention: .needsApproval)
        model.setAttention(threadID: "thread-local-core", attention: .failed)
        model.replacePullRequests(
            workspaceID: "git-kaname-local",
            records: [(
                repository: "cyber-lane/kaname-synthetic",
                number: 42,
                title: "Adopt semantic status language",
                url: "https://example.invalid/kaname/pull/42",
                headBranch: "design-system-statuses",
                baseBranch: "main",
                checkSummary: "12 synthetic checks passed",
                reviewSummary: "Owner approval required",
                mergeAfterIDs: [],
                state: .awaitingApproval,
                reconciledAtUnixMillis: 1_787_558_400_000
            )]
        )
    }
}
