// Synchronized from DesignSystem/kaname.tokens.json by
// Scripts/generate-kaname-design-tokens.py. Review this projection with source changes.

import Foundation

public enum KanameDesignSystemMetadata {
    public static let schemaVersion = 1
    public static let version = "0.2.0"
}

enum KanameDesignGeneratedHex {
    enum Nord {
        static let polarNight0 = "#2E3440"
        static let polarNight1 = "#3B4252"
        static let polarNight2 = "#434C5E"
        static let polarNight3 = "#4C566A"
        static let snowStorm0 = "#D8DEE9"
        static let snowStorm1 = "#E5E9F0"
        static let snowStorm2 = "#ECEFF4"
        static let frost0 = "#8FBCBB"
        static let frost1 = "#88C0D0"
        static let frost2 = "#81A1C1"
        static let frost3 = "#5E81AC"
        static let auroraRed = "#BF616A"
        static let auroraOrange = "#D08770"
        static let auroraYellow = "#EBCB8B"
        static let auroraGreen = "#A3BE8C"
        static let auroraPurple = "#B48EAD"
    }

    enum Dark {
        static let canvas = "#181B22"
        static let sidebar = "#20242D"
        static let surface = "#252A35"
        static let raised = "#2A303B"
        static let selected = "#34445A"
        static let separator = "#434C5E"
        static let textPrimary = "#ECEFF4"
        static let textSecondary = "#AAB2C0"
        static let textTertiary = "#929CAA"
        static let accent = "#88C0D0"
        static let accentStrong = "#5E81AC"
        static let active = "#8FBCBB"
        static let success = "#A3BE8C"
        static let warning = "#EBCB8B"
        static let danger = "#BF616A"
        static let blocked = "#B48EAD"
        static let external = "#D08770"
        static let focus = "#88C0D0"
    }

    enum Light {
        static let canvas = "#F4F6FA"
        static let sidebar = "#E9EDF4"
        static let surface = "#FFFFFF"
        static let raised = "#FFFFFF"
        static let selected = "#DCE7F4"
        static let separator = "#CDD3DE"
        static let textPrimary = "#20242D"
        static let textSecondary = "#556070"
        static let textTertiary = "#616B78"
        static let accent = "#466D99"
        static let accentStrong = "#365D8C"
        static let active = "#39706D"
        static let success = "#42713E"
        static let warning = "#8B6518"
        static let danger = "#9B3F49"
        static let blocked = "#764C72"
        static let external = "#92533D"
        static let focus = "#365D8C"
    }

}

enum KanameDesignGeneratedDimension {
    enum Spacing {
        static let hairline: Double = 2
        static let xSmall: Double = 4
        static let small: Double = 8
        static let medium: Double = 12
        static let large: Double = 16
        static let xLarge: Double = 20
        static let xxLarge: Double = 24
        static let xxxLarge: Double = 32
        static let huge: Double = 40
    }

    enum Radius {
        static let control: Double = 8
        static let card: Double = 12
        static let panel: Double = 16
        static let hero: Double = 20
    }

    enum Size {
        static let minimumInteractiveTarget: Double = 44
        static let compactControlHeight: Double = 28
        static let regularControlHeight: Double = 36
        static let sidebarIdealWidth: Double = 260
        static let collectionIdealWidth: Double = 330
        static let readableContentWidth: Double = 720
    }

    enum MotionSeconds {
        static let quick: Double = 0.12
        static let standard: Double = 0.2
        static let deliberate: Double = 0.32
    }

}

enum KanameDesignGeneratedColorRole {
    case textSecondary
    case accentStrong
    case active
    case warning
    case success
    case danger
    case blocked
    case external
}

enum KanameDesignGeneratedStatusKey {
    case neutral
    case informational
    case active
    case attention
    case success
    case warning
    case danger
    case blocked
    case external
}

enum KanameDesignGeneratedStatus {
    static func value(
        for status: KanameDesignGeneratedStatusKey
    ) -> (iconID: String, symbol: String, colorRole: KanameDesignGeneratedColorRole) {
        switch status {
        case .neutral: ("status.neutral", "circle", .textSecondary)
        case .informational: ("status.informational", "info.circle.fill", .accentStrong)
        case .active: ("status.active", "waveform.path.ecg", .active)
        case .attention: ("status.attention", "bell.badge.fill", .warning)
        case .success: ("status.success", "checkmark.circle.fill", .success)
        case .warning: ("status.warning", "exclamationmark.triangle.fill", .warning)
        case .danger: ("status.danger", "xmark.octagon.fill", .danger)
        case .blocked: ("status.blocked", "hand.raised.fill", .blocked)
        case .external: ("status.external", "person.2.badge.gearshape.fill", .external)
        }
    }
}
