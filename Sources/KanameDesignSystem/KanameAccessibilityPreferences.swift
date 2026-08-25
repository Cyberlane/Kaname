import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Deterministic accessibility conditions for catalogs and component previews.
/// Product views should combine these overrides with the native SwiftUI
/// accessibility environment instead of replacing system preferences.
public struct KanameAccessibilityPreferences: Equatable, Sendable {
    public var differentiateWithoutColor: Bool
    public var reduceMotion: Bool
    public var increasedContrast: Bool

    public init(
        differentiateWithoutColor: Bool = false,
        reduceMotion: Bool = false,
        increasedContrast: Bool = false
    ) {
        self.differentiateWithoutColor = differentiateWithoutColor
        self.reduceMotion = reduceMotion
        self.increasedContrast = increasedContrast
    }

    public static let system = Self()
}

#if os(macOS)
/// Posts a native announcement against Kaname's active window. Keeping this
/// boundary shared prevents Desktop and Link from drifting in priority or
/// window selection behavior.
public enum KanameAccessibilityAnnouncement {
    @MainActor
    public static func post(_ message: String) {
        guard !message.isEmpty,
              let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}
#endif

private struct KanameAccessibilityPreferencesKey: EnvironmentKey {
    static let defaultValue = KanameAccessibilityPreferences.system
}

public extension EnvironmentValues {
    var kanameAccessibilityPreferences: KanameAccessibilityPreferences {
        get { self[KanameAccessibilityPreferencesKey.self] }
        set { self[KanameAccessibilityPreferencesKey.self] = newValue }
    }
}
