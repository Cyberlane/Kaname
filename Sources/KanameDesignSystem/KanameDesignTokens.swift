import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// An sRGB color value that stays portable across SwiftUI, WinUI, GTK, and documentation.
public struct KanameRGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6 || value.count == 8,
              let raw = UInt64(value, radix: 16) else { return nil }
        let includesAlpha = value.count == 8
        let shift = includesAlpha ? 8 : 0
        red = Double((raw >> (16 + shift)) & 0xff) / 255
        green = Double((raw >> (8 + shift)) & 0xff) / 255
        blue = Double((raw >> shift) & 0xff) / 255
        alpha = includesAlpha ? Double(raw & 0xff) / 255 : 1
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

private extension KanameRGBColor {
    static func required(_ hex: String) -> Self {
        guard let value = Self(hex: hex) else {
            preconditionFailure("Invalid Kaname design token: \(hex)")
        }
        return value
    }
}

/// Stable primitive colors. Product UI should normally use ``KanameColor`` roles instead.
public enum Nord {
    public static let polarNight0 = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.polarNight0).color
    public static let polarNight1 = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.polarNight1).color
    public static let polarNight2 = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.polarNight2).color
    public static let polarNight3 = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.polarNight3).color
    public static let snowStorm0 = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.snowStorm0).color
    public static let snowStorm1 = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.snowStorm1).color
    public static let snowStorm2 = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.snowStorm2).color
    public static let frost0 = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.frost0).color
    public static let frost1 = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.frost1).color
    public static let frost2 = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.frost2).color
    public static let frost3 = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.frost3).color
    public static let auroraRed = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.auroraRed).color
    public static let auroraOrange = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.auroraOrange).color
    public static let auroraYellow = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.auroraYellow).color
    public static let auroraGreen = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.auroraGreen).color
    public static let auroraPurple = KanameRGBColor.required(KanameDesignGeneratedHex.Nord.auroraPurple).color
}

private enum KanameAdaptiveColor {
    static func color(light: String, dark: String) -> Color {
        let lightValue = KanameRGBColor.required(light)
        let darkValue = KanameRGBColor.required(dark)
#if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? darkValue : lightValue
            return NSColor(
                srgbRed: value.red,
                green: value.green,
                blue: value.blue,
                alpha: value.alpha
            )
        })
#elseif os(iOS)
        return Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? darkValue : lightValue
            return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
        })
#else
        return darkValue.color
#endif
    }
}

/// Semantic colors shared by Kaname Desktop, iOS, and Link.
public enum KanameColor {
    public static let canvas = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.canvas, dark: KanameDesignGeneratedHex.Dark.canvas)
    public static let sidebar = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.sidebar, dark: KanameDesignGeneratedHex.Dark.sidebar)
    public static let surface = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.surface, dark: KanameDesignGeneratedHex.Dark.surface)
    public static let raised = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.raised, dark: KanameDesignGeneratedHex.Dark.raised)
    public static let selected = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.selected, dark: KanameDesignGeneratedHex.Dark.selected)
    public static let separator = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.separator, dark: KanameDesignGeneratedHex.Dark.separator)
    public static let textPrimary = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.textPrimary, dark: KanameDesignGeneratedHex.Dark.textPrimary)
    public static let textSecondary = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.textSecondary, dark: KanameDesignGeneratedHex.Dark.textSecondary)
    public static let textTertiary = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.textTertiary, dark: KanameDesignGeneratedHex.Dark.textTertiary)
    public static let accent = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.accent, dark: KanameDesignGeneratedHex.Dark.accent)
    public static let accentStrong = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.accentStrong, dark: KanameDesignGeneratedHex.Dark.accentStrong)
    public static let active = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.active, dark: KanameDesignGeneratedHex.Dark.active)
    public static let success = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.success, dark: KanameDesignGeneratedHex.Dark.success)
    public static let warning = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.warning, dark: KanameDesignGeneratedHex.Dark.warning)
    public static let danger = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.danger, dark: KanameDesignGeneratedHex.Dark.danger)
    public static let blocked = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.blocked, dark: KanameDesignGeneratedHex.Dark.blocked)
    public static let external = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.external, dark: KanameDesignGeneratedHex.Dark.external)
    public static let focus = KanameAdaptiveColor.color(light: KanameDesignGeneratedHex.Light.focus, dark: KanameDesignGeneratedHex.Dark.focus)
}

public enum KanameSpacing {
    public static let hairline = CGFloat(KanameDesignGeneratedDimension.Spacing.hairline)
    public static let xSmall = CGFloat(KanameDesignGeneratedDimension.Spacing.xSmall)
    public static let small = CGFloat(KanameDesignGeneratedDimension.Spacing.small)
    public static let medium = CGFloat(KanameDesignGeneratedDimension.Spacing.medium)
    public static let large = CGFloat(KanameDesignGeneratedDimension.Spacing.large)
    public static let xLarge = CGFloat(KanameDesignGeneratedDimension.Spacing.xLarge)
    public static let xxLarge = CGFloat(KanameDesignGeneratedDimension.Spacing.xxLarge)
    public static let xxxLarge = CGFloat(KanameDesignGeneratedDimension.Spacing.xxxLarge)
    public static let huge = CGFloat(KanameDesignGeneratedDimension.Spacing.huge)
}

public enum KanameRadius {
    public static let control = CGFloat(KanameDesignGeneratedDimension.Radius.control)
    public static let card = CGFloat(KanameDesignGeneratedDimension.Radius.card)
    public static let panel = CGFloat(KanameDesignGeneratedDimension.Radius.panel)
    public static let hero = CGFloat(KanameDesignGeneratedDimension.Radius.hero)
}

public enum KanameSize {
    public static let minimumInteractiveTarget = CGFloat(KanameDesignGeneratedDimension.Size.minimumInteractiveTarget)
    public static let compactControlHeight = CGFloat(KanameDesignGeneratedDimension.Size.compactControlHeight)
    public static let regularControlHeight = CGFloat(KanameDesignGeneratedDimension.Size.regularControlHeight)
    public static let sidebarIdealWidth = CGFloat(KanameDesignGeneratedDimension.Size.sidebarIdealWidth)
    public static let collectionIdealWidth = CGFloat(KanameDesignGeneratedDimension.Size.collectionIdealWidth)
    public static let readableContentWidth = CGFloat(KanameDesignGeneratedDimension.Size.readableContentWidth)
}

public enum KanameMotion {
    public static let quick = KanameDesignGeneratedDimension.MotionSeconds.quick
    public static let standard = KanameDesignGeneratedDimension.MotionSeconds.standard
    public static let deliberate = KanameDesignGeneratedDimension.MotionSeconds.deliberate
}

public enum KanameTypography {
    public static let display = Font.system(.largeTitle, design: .rounded, weight: .bold)
    public static let screenTitle = Font.title2.weight(.bold)
    public static let sectionTitle = Font.headline
    public static let body = Font.body
    public static let supporting = Font.subheadline
    public static let metadata = Font.caption
    public static let technical = Font.system(.caption, design: .monospaced, weight: .medium)
}

/// Meaning is always conveyed with text and a symbol in addition to color.
public enum KanameStatusTone: String, CaseIterable, Codable, Sendable {
    case neutral
    case informational
    case active
    case attention
    case success
    case warning
    case danger
    case blocked
    case external

    public var color: Color {
        switch generatedColorRole {
        case .textSecondary: KanameColor.textSecondary
        case .accentStrong: KanameColor.accentStrong
        case .active: KanameColor.active
        case .warning: KanameColor.warning
        case .success: KanameColor.success
        case .danger: KanameColor.danger
        case .blocked: KanameColor.blocked
        case .external: KanameColor.external
        }
    }

    private var generatedColorRole: KanameDesignGeneratedColorRole {
        KanameDesignGeneratedStatus.value(for: generatedStatusKey).colorRole
    }

    private var generatedStatusKey: KanameDesignGeneratedStatusKey {
        switch self {
        case .neutral: .neutral
        case .informational: .informational
        case .active: .active
        case .attention: .attention
        case .success: .success
        case .warning: .warning
        case .danger: .danger
        case .blocked: .blocked
        case .external: .external
        }
    }

    public var symbolName: String {
        KanameDesignGeneratedStatus.value(for: generatedStatusKey).symbol
    }
}
