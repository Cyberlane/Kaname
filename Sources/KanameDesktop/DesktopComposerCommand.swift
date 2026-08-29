import Foundation

public enum DesktopComposerCommandID: String, CaseIterable, Identifiable, Sendable {
    case model
    case runtime
    case chat
    case diff
    case plan
    case checks
    case rename

    public var id: String { rawValue }
    public var invocation: String { "/\(rawValue)" }

    public var title: String {
        switch self {
        case .model: "Choose model"
        case .runtime: "Conversation runtime"
        case .chat: "Open Chat"
        case .diff: "Open Diff"
        case .plan: "Open Plan"
        case .checks: "Open Checks"
        case .rename: "Rename conversation"
        }
    }

    public var detail: String {
        switch self {
        case .model: "Choose the provider model used for future turns."
        case .runtime: "Review provider, model, thinking, permissions, and network access."
        case .chat: "Return to the conversation timeline."
        case .diff: "Inspect the current conversation changes."
        case .plan: "Review the structured plan without changing its authority."
        case .checks: "Inspect verification and implementation evidence."
        case .rename: "Give this conversation a durable manual title."
        }
    }

    public var systemImage: String {
        switch self {
        case .model: "cpu"
        case .runtime: "slider.horizontal.3"
        case .chat: "bubble.left.and.bubble.right"
        case .diff: "doc.text.magnifyingglass"
        case .plan: "list.bullet.clipboard"
        case .checks: "checkmark.seal"
        case .rename: "pencil"
        }
    }

    fileprivate var searchTerms: [String] {
        switch self {
        case .model: [rawValue, title, detail, "provider choose"]
        case .runtime: [rawValue, title, detail, "settings permissions network thinking"]
        case .chat: [rawValue, title, detail, "conversation messages"]
        case .diff: [rawValue, title, detail, "changes patch"]
        case .plan: [rawValue, title, detail, "planning steps"]
        case .checks: [rawValue, title, detail, "evidence tests verification"]
        case .rename: [rawValue, title, detail, "title"]
        }
    }
}

public struct DesktopComposerCommand: Identifiable, Equatable, Sendable {
    public let id: DesktopComposerCommandID
    public let disabledReason: String?

    public init(id: DesktopComposerCommandID, disabledReason: String? = nil) {
        self.id = id
        self.disabledReason = disabledReason
    }

    public var isEnabled: Bool { disabledReason == nil }
    public var invocation: String { id.invocation }
    public var title: String { id.title }
    public var detail: String { id.detail }
    public var systemImage: String { id.systemImage }
}

public struct DesktopComposerCommandQuery: Equatable, Sendable {
    public let fragment: String
    public let triggerRange: Range<Int>

    public init(fragment: String, triggerRange: Range<Int>) {
        self.fragment = fragment
        self.triggerRange = triggerRange
    }
}

public struct DesktopComposerCommandEdit: Equatable, Sendable {
    public let text: String
    public let insertionOffset: Int

    public init(text: String, insertionOffset: Int) {
        self.text = text
        self.insertionOffset = insertionOffset
    }
}

public struct DesktopComposerSelectionProjection: Equatable, Sendable {
    public let cursorOffset: Int
    public let hasSelection: Bool
    public let recoveredStaleSelection: Bool

    public init(cursorOffset: Int, hasSelection: Bool, recoveredStaleSelection: Bool) {
        self.cursorOffset = cursorOffset
        self.hasSelection = hasSelection
        self.recoveredStaleSelection = recoveredStaleSelection
    }

    public static func project(
        _ range: Range<String.Index>,
        in text: String,
        fallbackCursorOffset: Int?
    ) -> DesktopComposerSelectionProjection {
        guard
            let lowerBound = range.lowerBound.samePosition(in: text),
            let upperBound = range.upperBound.samePosition(in: text)
        else {
            return DesktopComposerSelectionProjection(
                cursorOffset: min(max(fallbackCursorOffset ?? text.count, 0), text.count),
                hasSelection: false,
                recoveredStaleSelection: true
            )
        }

        return DesktopComposerSelectionProjection(
            cursorOffset: text.distance(from: text.startIndex, to: lowerBound),
            hasSelection: lowerBound != upperBound,
            recoveredStaleSelection: false
        )
    }
}

public enum DesktopComposerCommandResolution: Equatable, Sendable {
    case local(DesktopComposerCommandID, edit: DesktopComposerCommandEdit)
    case disabled(DesktopComposerCommandID, reason: String)
    case message
}

public typealias DesktopComposerCommandSelectionDirection = DesktopCyclicSelectionDirection

public struct DesktopComposerCommandSelectionState: Equatable, Sendable {
    public private(set) var selectedCommandID: DesktopComposerCommandID?

    public init(selectedCommandID: DesktopComposerCommandID? = nil) {
        self.selectedCommandID = selectedCommandID
    }

    public mutating func reconcile(with commands: [DesktopComposerCommand]) {
        if let selectedCommandID, commands.contains(where: { $0.id == selectedCommandID }) {
            return
        }
        selectedCommandID = commands.first?.id
    }

    public mutating func move(
        _ direction: DesktopComposerCommandSelectionDirection,
        in commands: [DesktopComposerCommand]
    ) {
        selectedCommandID = DesktopCyclicSelection.moving(
            selectedCommandID,
            direction,
            in: commands.map(\.id)
        )
    }

    public func command(in commands: [DesktopComposerCommand]) -> DesktopComposerCommand? {
        guard let selectedCommandID else { return nil }
        return commands.first { $0.id == selectedCommandID }
    }
}

public enum DesktopComposerReturnDisposition: Equatable, Sendable {
    case submit
    case insertNewline
    case nativeEditing
}

public enum DesktopComposerReturnPolicy {
    public static func disposition(
        shift: Bool = false,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        hasMarkedText: Bool = false
    ) -> DesktopComposerReturnDisposition {
        guard !hasMarkedText, !command, !option, !control else {
            return .nativeEditing
        }
        return shift ? .insertNewline : .submit
    }
}

public enum DesktopComposerPresentation {
    public static let minimumLines = 1
    public static let maximumLines = 8
    public static let inputPointSize: CGFloat = 16
    public static let toolbarPointSize: CGFloat = 13
    public static let contextPointSize: CGFloat = 12.5
    public static let maximumWidth: CGFloat = 760
    public static let cornerRadius: CGFloat = 20
    public static let inputHorizontalPadding: CGFloat = 16
    public static let inputTopPadding: CGFloat = 14
    public static let inputBottomPadding: CGFloat = 12

    public static func primaryAction(
        isRunning: Bool,
        hasSendableContent: Bool,
        canSend: Bool,
        isImportingAttachments: Bool,
        selectedCommandIsEnabled: Bool?
    ) -> DesktopComposerPrimaryAction {
        if let selectedCommandIsEnabled {
            return DesktopComposerPrimaryAction(kind: .run, isEnabled: selectedCommandIsEnabled)
        }
        if isRunning, !hasSendableContent {
            return DesktopComposerPrimaryAction(kind: .stop, isEnabled: true)
        }
        let kind: DesktopComposerPrimaryAction.Kind = isRunning ? .queue : .send
        return DesktopComposerPrimaryAction(
            kind: kind,
            isEnabled: canSend && hasSendableContent && !isImportingAttachments
        )
    }
}

public struct DesktopComposerPrimaryAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case send
        case queue
        case stop
        case run
    }

    public let kind: Kind
    public let isEnabled: Bool

    public init(kind: Kind, isEnabled: Bool) {
        self.kind = kind
        self.isEnabled = isEnabled
    }

    public var title: String {
        switch kind {
        case .send: "Send"
        case .queue: "Queue"
        case .stop: "Stop"
        case .run: "Run"
        }
    }

    public var systemImage: String {
        switch kind {
        case .send: "arrow.up"
        case .queue: "text.badge.plus"
        case .stop: "stop.fill"
        case .run: "return"
        }
    }
}

public enum DesktopComposerCommands {
    public static func catalog(
        disabledReason: (DesktopComposerCommandID) -> String? = { _ in nil }
    ) -> [DesktopComposerCommand] {
        DesktopComposerCommandID.allCases.map {
            DesktopComposerCommand(id: $0, disabledReason: disabledReason($0))
        }
    }

    public static func query(
        in text: String,
        selection: Range<String.Index>? = nil
    ) -> DesktopComposerCommandQuery? {
        let selectedRange = selection ?? text.endIndex..<text.endIndex
        guard selectedRange.isEmpty else { return nil }
        return query(
            in: text,
            cursorOffset: text.distance(from: text.startIndex, to: selectedRange.lowerBound)
        )
    }

    public static func query(
        in text: String,
        cursorOffset: Int,
        hasSelection: Bool = false
    ) -> DesktopComposerCommandQuery? {
        guard let inline = DesktopComposerInlineQueries.query(
            in: text,
            cursorOffset: cursorOffset,
            hasSelection: hasSelection,
            trigger: "/",
            placement: .lineStart
        ) else { return nil }
        return DesktopComposerCommandQuery(
            fragment: inline.fragment,
            triggerRange: inline.triggerRange
        )
    }

    public static func matching(
        _ query: DesktopComposerCommandQuery,
        in commands: [DesktopComposerCommand]
    ) -> [DesktopComposerCommand] {
        DesktopComposerInlineQueries.rankedMatches(
            query: DesktopComposerInlineQuery(fragment: query.fragment, triggerRange: query.triggerRange),
            in: commands,
            rank: { command, normalizedQuery in
                rank(command.id, for: normalizedQuery)
            }
        )
    }

    public static func consuming(
        _ query: DesktopComposerCommandQuery,
        from text: String
    ) -> DesktopComposerCommandEdit? {
        guard let consumed = DesktopComposerInlineQueries.consuming(
            DesktopComposerInlineQuery(fragment: query.fragment, triggerRange: query.triggerRange),
            replacement: "",
            from: text
        ) else { return nil }
        return DesktopComposerCommandEdit(
            text: consumed.text,
            insertionOffset: consumed.insertionOffset
        )
    }

    public static func resolveSubmission(
        text: String,
        query: DesktopComposerCommandQuery?,
        selectedCommandID: DesktopComposerCommandID?,
        commands: [DesktopComposerCommand]
    ) -> DesktopComposerCommandResolution {
        guard let query else { return .message }
        let matches = matching(query, in: commands)
        guard let command = matches.first(where: { $0.id == selectedCommandID }) ?? matches.first else {
            return .message
        }
        if let disabledReason = command.disabledReason {
            return .disabled(command.id, reason: disabledReason)
        }
        guard let edit = consuming(query, from: text) else { return .message }
        return .local(command.id, edit: edit)
    }

    private static func rank(_ command: DesktopComposerCommandID, for query: String) -> Int? {
        let terms = command.searchTerms.map(normalized)
        guard let name = terms.first else { return nil }
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        guard query.count > 1 else { return nil }
        if terms.dropFirst().contains(where: { $0.hasPrefix(query) }) { return 2 }
        if terms.contains(where: { term in
            term.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(query) })
        }) { return 3 }
        if terms.contains(where: { $0.contains(query) }) { return 4 }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }
}
