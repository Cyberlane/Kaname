import Foundation

enum DesktopConversationOrdering {
    static func stable<Value>(
        _ values: [Value],
        createdAt: (Value) -> Int64
    ) -> [Value] {
        values.enumerated().sorted { left, right in
            let leftTime = createdAt(left.element)
            let rightTime = createdAt(right.element)
            if leftTime != rightTime { return leftTime < rightTime }
            return left.offset < right.offset
        }.map(\.element)
    }
}

public enum DesktopConversationTimelineEntry: Equatable, Identifiable, Sendable {
    case message(DesktopMessage)
    case event(DesktopProviderEventRecord)

    public var id: String {
        switch self {
        case let .message(message): "message-\(message.id)"
        case let .event(event): "event-\(event.id)"
        }
    }

    public var createdAtUnixMillis: Int64 {
        switch self {
        case let .message(message): message.createdAtUnixMillis
        case let .event(event): event.createdAtUnixMillis
        }
    }
}

public struct DesktopProviderEventGroup: Equatable, Identifiable, Sendable {
    public let id: String
    public let events: [DesktopProviderEventRecord]

    init(events: [DesktopProviderEventRecord]) {
        precondition(events.count >= 2)
        self.id = "event-group-\(events[0].threadID)-\(events[0].id)"
        self.events = events
    }

    public var kind: DesktopProviderEventKind { events[0].kind }
    public var count: Int { events.count }
    public var latestEvent: DesktopProviderEventRecord { events[events.count - 1] }
    public var latestCreatedAtUnixMillis: Int64 { latestEvent.createdAtUnixMillis }
    public var containsTruncatedPayload: Bool { events.contains(where: \.payloadWasTruncated) }

    public var summaryTitle: String {
        "\(count) \(kind.groupSummaryNoun(count: count))"
    }

    public var latestSummary: String {
        let title = latestEvent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = latestEvent.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return detail }
        guard !detail.isEmpty, detail.caseInsensitiveCompare(title) != .orderedSame else { return title }
        return "\(title) · \(detail)"
    }

    public func accessibilityLabel(isExpanded: Bool) -> String {
        var components = [summaryTitle]
        if !latestSummary.isEmpty {
            components.append("Latest: \(latestSummary)")
        }
        if containsTruncatedPayload {
            components.append("One or more raw payloads exceeded the evidence limit")
        }
        components.append(isExpanded ? "Expanded" : "Collapsed")
        return components.joined(separator: ". ")
    }
}

public enum DesktopConversationTimelineRow: Equatable, Identifiable, Sendable {
    case message(DesktopMessage)
    case event(DesktopProviderEventRecord)
    case eventGroup(DesktopProviderEventGroup)

    public var id: String {
        switch self {
        case let .message(message): "message-\(message.id)"
        case let .event(event): "event-\(event.id)"
        case let .eventGroup(group): group.id
        }
    }

    public var createdAtUnixMillis: Int64 {
        switch self {
        case let .message(message): message.createdAtUnixMillis
        case let .event(event): event.createdAtUnixMillis
        case let .eventGroup(group): group.events[0].createdAtUnixMillis
        }
    }
}

public struct DesktopConversationTimelinePage: Equatable, Sendable {
    public let rows: [DesktopConversationTimelineRow]
    public let hiddenOlderEntryCount: Int

    public init(rows: [DesktopConversationTimelineRow], hiddenOlderEntryCount: Int) {
        self.rows = rows
        self.hiddenOlderEntryCount = hiddenOlderEntryCount
    }
}

public enum DesktopConversationTimelinePresentation {
    public static let defaultMaximumEntries = 400

    public static func rows(
        messages: [DesktopMessage],
        providerEvents: [DesktopProviderEventRecord]
    ) -> [DesktopConversationTimelineRow] {
        page(
            messages: messages,
            providerEvents: providerEvents,
            maximumEntries: Int.max
        ).rows
    }

    public static func page(
        messages: [DesktopMessage],
        providerEvents: [DesktopProviderEventRecord],
        maximumEntries: Int = defaultMaximumEntries
    ) -> DesktopConversationTimelinePage {
        let entries = messages.map(DesktopConversationTimelineEntry.message)
            + providerEvents
                .filter(\.kind.isVisibleInConversationTimeline)
                .map(DesktopConversationTimelineEntry.event)
        let orderedEntries = DesktopConversationOrdering.stable(entries, createdAt: \.createdAtUnixMillis)
        let retainedCount = min(max(1, maximumEntries), orderedEntries.count)
        let hiddenCount = orderedEntries.count - retainedCount
        return DesktopConversationTimelinePage(
            rows: rows(from: Array(orderedEntries.suffix(retainedCount))),
            hiddenOlderEntryCount: hiddenCount
        )
    }

    public static func rows(
        from entries: [DesktopConversationTimelineEntry]
    ) -> [DesktopConversationTimelineRow] {
        var rows: [DesktopConversationTimelineRow] = []
        rows.reserveCapacity(entries.count)
        var index = entries.startIndex

        while index < entries.endIndex {
            switch entries[index] {
            case let .message(message):
                rows.append(.message(message))
                index += 1
            case let .event(firstEvent):
                guard firstEvent.kind.isCollapsibleConversationChatter else {
                    rows.append(.event(firstEvent))
                    index += 1
                    continue
                }

                var groupedEvents = [firstEvent]
                var cursor = index + 1
                while cursor < entries.endIndex,
                      case let .event(nextEvent) = entries[cursor],
                      nextEvent.kind.isCollapsibleConversationChatter,
                      nextEvent.threadID == firstEvent.threadID,
                      nextEvent.runID == firstEvent.runID,
                      nextEvent.kind == firstEvent.kind {
                    groupedEvents.append(nextEvent)
                    cursor += 1
                }

                if groupedEvents.count >= 2 {
                    rows.append(.eventGroup(DesktopProviderEventGroup(events: groupedEvents)))
                } else {
                    rows.append(.event(firstEvent))
                }
                index = cursor
            }
        }

        return rows
    }
}

private extension DesktopProviderEventKind {
    var isVisibleInConversationTimeline: Bool {
        self != .assistantText && self != .native
    }

    var isCollapsibleConversationChatter: Bool {
        switch self {
        case .status, .reasoning, .tool, .diff, .usage:
            true
        case .question, .approval, .error, .assistantText, .native:
            false
        }
    }

    func groupSummaryNoun(count: Int) -> String {
        switch self {
        case .status: count == 1 ? "status update" : "status updates"
        case .reasoning: count == 1 ? "reasoning update" : "reasoning updates"
        case .tool: count == 1 ? "tool activity" : "tool activities"
        case .diff: count == 1 ? "diff update" : "diff updates"
        case .usage: count == 1 ? "usage update" : "usage updates"
        case .question: count == 1 ? "question" : "questions"
        case .approval: count == 1 ? "approval" : "approvals"
        case .error: count == 1 ? "error" : "errors"
        case .assistantText: count == 1 ? "response update" : "response updates"
        case .native: count == 1 ? "provider event" : "provider events"
        }
    }
}
