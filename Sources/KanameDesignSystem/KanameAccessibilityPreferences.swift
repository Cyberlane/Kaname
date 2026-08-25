import SwiftUI

#if os(macOS)
import AppKit
#endif

/// A deterministic text-size input for synthetic design qualification.
///
/// SwiftUI's Dynamic Type environment does not resize text on macOS. Kaname
/// therefore uses this explicit scale only when rendering synthetic macOS
/// fixtures. It is visual stress evidence, not proof of a native macOS user
/// preference or assistive-technology qualification. Apple platforms that
/// support Dynamic Type continue to use the native environment instead.
public enum KanameSyntheticTextScale: String, CaseIterable, Codable, Sendable {
    case standard
    case accessibility3

    /// The stable multiplier used by Kaname's macOS semantic-font adapter.
    /// The accessibility value is intentionally conspicuous so fixed-width
    /// product layouts cannot pass qualification without adapting.
    public var fontScaleFactor: CGFloat {
        switch self {
        case .standard: 1
        case .accessibility3: 1.6
        }
    }
}

/// Deterministic accessibility conditions for catalogs and component previews.
/// Product views should combine these overrides with the native SwiftUI
/// accessibility environment instead of replacing system preferences.
public struct KanameAccessibilityPreferences: Equatable, Sendable {
    public var differentiateWithoutColor: Bool
    public var reduceMotion: Bool
    public var increasedContrast: Bool
    public var syntheticTextScale: KanameSyntheticTextScale

    public init(
        differentiateWithoutColor: Bool = false,
        reduceMotion: Bool = false,
        increasedContrast: Bool = false,
        syntheticTextScale: KanameSyntheticTextScale = .standard
    ) {
        self.differentiateWithoutColor = differentiateWithoutColor
        self.reduceMotion = reduceMotion
        self.increasedContrast = increasedContrast
        self.syntheticTextScale = syntheticTextScale
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

/// Applies a semantic font and honors Kaname's explicit synthetic macOS text
/// scale. At the standard scale this is exactly the ordinary SwiftUI font
/// modifier. Other platforms retain their native Dynamic Type behavior.
public extension View {
    func kanameSemanticFont(_ font: Font) -> some View {
        modifier(KanameSemanticFontModifier(font: font))
    }
}

private struct KanameSemanticFontModifier: ViewModifier {
    @Environment(\.kanameAccessibilityPreferences) private var accessibilityPreferences
    let font: Font

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(macOS)
        if accessibilityPreferences.syntheticTextScale == .standard {
            content.font(font)
        } else {
            content.font(font.scaled(by: accessibilityPreferences.syntheticTextScale.fontScaleFactor))
        }
#else
        content.font(font)
#endif
    }
}
