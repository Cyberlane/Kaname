public enum DesktopCyclicSelectionDirection: Sendable {
    case previous
    case next
}

public enum DesktopCyclicSelection {
    public static func moving<ID: Equatable>(
        _ selectedID: ID?,
        _ direction: DesktopCyclicSelectionDirection,
        in identifiers: [ID]
    ) -> ID? {
        guard !identifiers.isEmpty else { return nil }
        guard let selectedID,
              let currentIndex = identifiers.firstIndex(of: selectedID) else {
            return identifiers.first
        }
        switch direction {
        case .previous:
            return identifiers[
                currentIndex == identifiers.startIndex
                    ? identifiers.index(before: identifiers.endIndex)
                    : identifiers.index(before: currentIndex)
            ]
        case .next:
            let nextIndex = identifiers.index(after: currentIndex)
            return identifiers[nextIndex == identifiers.endIndex ? identifiers.startIndex : nextIndex]
        }
    }
}
