import SwiftUI

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

private struct KanameAccessibilityPreferencesKey: EnvironmentKey {
    static let defaultValue = KanameAccessibilityPreferences.system
}

public extension EnvironmentValues {
    var kanameAccessibilityPreferences: KanameAccessibilityPreferences {
        get { self[KanameAccessibilityPreferencesKey.self] }
        set { self[KanameAccessibilityPreferencesKey.self] = newValue }
    }
}
