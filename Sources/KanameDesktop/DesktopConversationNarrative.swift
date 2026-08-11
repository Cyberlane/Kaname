import Foundation

/// A compact, provider-neutral projection of one run. The complete event stream
/// remains durable; this summary is deliberately cheap enough to render in a
/// very long conversation.
public struct DesktopConversationRunSummary: Equatable, Identifiable, Sendable {
    public let run: DesktopProviderRunRecord
    public let events: [DesktopProviderEventRecord]

    public init(run: DesktopProviderRunRecord, events: [DesktopProviderEventRecord]) {
        self.run = run
        self.events = events
    }

    public var id: String { run.id }

    public var criticalEvents: [DesktopProviderEventRecord] {
        events.filter { $0.kind.isNarrativeCritical }
    }

    public var activityCount: Int {
        events.lazy.filter { !$0.kind.isTransportOnly }.count
    }

    public var toolCount: Int { count(.tool) }
    public var diffCount: Int { count(.diff) }
    public var reasoningCount: Int { count(.reasoning) }
    public var errorCount: Int { count(.error) }
    public var payloadWasTruncated: Bool { events.contains(where: \.payloadWasTruncated) }

    public var latestActivity: DesktopProviderEventRecord? {
        events.max { $0.createdAtUnixMillis < $1.createdAtUnixMillis }
    }

    public var presentationTimeUnixMillis: Int64 {
        run.completedAtUnixMillis ?? latestActivity?.createdAtUnixMillis ?? run.startedAtUnixMillis
    }

    public var durationLabel: String? {
        guard let completedAt = run.completedAtUnixMillis else { return nil }
        let seconds = max(0, completedAt - run.startedAtUnixMillis) / 1_000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    public var conciseActivityLabel: String {
        var parts: [String] = []
        if toolCount > 0 { parts.append("\(toolCount) tool\(toolCount == 1 ? "" : "s")") }
        if diffCount > 0 { parts.append("\(diffCount) diff\(diffCount == 1 ? "" : "s")") }
        if reasoningCount > 0 { parts.append("\(reasoningCount) reasoning") }
        if errorCount > 0 { parts.append("\(errorCount) error\(errorCount == 1 ? "" : "s")") }
        if parts.isEmpty, activityCount > 0 { parts.append("\(activityCount) update\(activityCount == 1 ? "" : "s")") }
        if let durationLabel { parts.append(durationLabel) }
        if let usage = run.tokenUsage { parts.append("\(usage) tokens") }
        return parts.isEmpty ? "No recorded activity" : parts.joined(separator: " · ")
    }

    private func count(_ kind: DesktopProviderEventKind) -> Int {
        events.lazy.filter { $0.kind == kind }.count
    }
}

public enum DesktopConversationNarrativeRow: Equatable, Identifiable, Sendable {
    case message(DesktopMessage)
    case criticalEvent(DesktopProviderEventRecord)
    case runSummary(DesktopConversationRunSummary)

    public var id: String {
        switch self {
        case let .message(message): "message-\(message.id)"
        case let .criticalEvent(event): "critical-\(event.id)"
        case let .runSummary(summary): "run-\(summary.id)"
        }
    }

    public var createdAtUnixMillis: Int64 {
        switch self {
        case let .message(message): message.createdAtUnixMillis
        case let .criticalEvent(event): event.createdAtUnixMillis
        case let .runSummary(summary): summary.presentationTimeUnixMillis
        }
    }

    public func matches(searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        switch self {
        case let .message(message):
            return message.body.localizedCaseInsensitiveContains(query)
        case let .criticalEvent(event):
            return event.title.localizedCaseInsensitiveContains(query)
                || event.detail.localizedCaseInsensitiveContains(query)
        case let .runSummary(summary):
            return summary.run.provider.localizedCaseInsensitiveContains(query)
                || summary.run.model.localizedCaseInsensitiveContains(query)
                || summary.run.state.label.localizedCaseInsensitiveContains(query)
                || summary.events.contains {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || $0.detail.localizedCaseInsensitiveContains(query)
                }
        }
    }
}

public struct DesktopConversationNarrativePage: Equatable, Sendable {
    public let rows: [DesktopConversationNarrativeRow]
    public let hiddenOlderRowCount: Int

    public init(rows: [DesktopConversationNarrativeRow], hiddenOlderRowCount: Int) {
        self.rows = rows
        self.hiddenOlderRowCount = hiddenOlderRowCount
    }
}

public enum DesktopConversationNarrativePresentation {
    public static let defaultMaximumRows = 120

    public static func runSummaries(
        runs: [DesktopProviderRunRecord],
        events: [DesktopProviderEventRecord]
    ) -> [DesktopConversationRunSummary] {
        let eventsByRun = Dictionary(grouping: events, by: \.runID)
        return runs.map { run in
            DesktopConversationRunSummary(
                run: run,
                events: (eventsByRun[run.id] ?? []).sorted {
                    if $0.createdAtUnixMillis != $1.createdAtUnixMillis {
                        return $0.createdAtUnixMillis < $1.createdAtUnixMillis
                    }
                    return $0.id < $1.id
                }
            )
        }
    }

    public static func page(
        messages: [DesktopMessage],
        runs: [DesktopProviderRunRecord],
        events: [DesktopProviderEventRecord],
        maximumRows: Int = defaultMaximumRows,
        searchText: String = ""
    ) -> DesktopConversationNarrativePage {
        let summaries = runSummaries(runs: runs, events: events)
        let rows = messages.map(DesktopConversationNarrativeRow.message)
            + summaries.flatMap { summary in
                summary.criticalEvents.map(DesktopConversationNarrativeRow.criticalEvent)
                    + [.runSummary(summary)]
            }
        let ordered = DesktopConversationOrdering.stable(rows, createdAt: \.createdAtUnixMillis)
        let matching = ordered.filter { $0.matches(searchText: searchText) }
        let retainedCount = min(max(1, maximumRows), matching.count)
        return DesktopConversationNarrativePage(
            rows: Array(matching.suffix(retainedCount)),
            hiddenOlderRowCount: matching.count - retainedCount
        )
    }
}

public extension DesktopProviderEventKind {
    var isNarrativeCritical: Bool {
        switch self {
        case .question, .approval, .error: true
        case .status, .assistantText, .reasoning, .tool, .diff, .usage, .native: false
        }
    }

    var isTransportOnly: Bool {
        self == .assistantText || self == .native
    }
}
