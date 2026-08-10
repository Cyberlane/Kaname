import Foundation

/// A value-semantic request that lets the desktop shell move keyboard focus to
/// a specific conversation composer after navigation or sheet dismissal.
public struct DesktopComposerFocusRequest: Equatable, Sendable {
    public let threadID: String
    public let generation: UInt64

    public init(threadID: String, generation: UInt64) {
        self.threadID = threadID
        self.generation = generation
    }

    public static func next(
        after current: DesktopComposerFocusRequest?,
        threadID: String
    ) -> DesktopComposerFocusRequest? {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return nil }
        return DesktopComposerFocusRequest(
            threadID: normalizedThreadID,
            generation: (current?.generation ?? 0) &+ 1
        )
    }
}

/// Deterministic sizing guidance for desktop sheets. The values intentionally
/// leave room for the window chrome on a 1080 x 700 display and make large-text
/// sheets scroll instead of growing beyond the visible screen.
public struct DesktopAccessibleSheetMetrics: Equatable, Sendable {
    public let minimumWidth: Double
    public let idealWidth: Double
    public let maximumWidth: Double
    public let minimumHeight: Double?
    public let idealHeight: Double?
    public let maximumHeight: Double?

    public static func adaptive(
        idealWidth: Double,
        idealHeight: Double? = nil,
        usesAccessibilityTextSize: Bool
    ) -> DesktopAccessibleSheetMetrics {
        let safeIdealWidth = min(max(idealWidth, 420), usesAccessibilityTextSize ? 760 : 720)
        let minimumWidth = min(safeIdealWidth, usesAccessibilityTextSize ? 380 : 420)
        let maximumWidth = min(920, max(safeIdealWidth, idealWidth + (usesAccessibilityTextSize ? 120 : 40)))

        guard let idealHeight else {
            return DesktopAccessibleSheetMetrics(
                minimumWidth: minimumWidth,
                idealWidth: safeIdealWidth,
                maximumWidth: maximumWidth,
                minimumHeight: nil,
                idealHeight: nil,
                maximumHeight: nil
            )
        }

        let safeIdealHeight = min(max(idealHeight, 300), usesAccessibilityTextSize ? 560 : 620)
        return DesktopAccessibleSheetMetrics(
            minimumWidth: minimumWidth,
            idealWidth: safeIdealWidth,
            maximumWidth: maximumWidth,
            minimumHeight: min(safeIdealHeight, usesAccessibilityTextSize ? 340 : 360),
            idealHeight: safeIdealHeight,
            maximumHeight: usesAccessibilityTextSize ? 640 : 660
        )
    }
}
