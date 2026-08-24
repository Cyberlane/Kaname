import Foundation

public struct KanameDesignScenario: Codable, Equatable, Identifiable, Sendable {
    public enum Platform: String, Codable, Sendable {
        case macOS
        case iOS
        case windows
        case linux
    }

    public enum Appearance: String, Codable, Sendable {
        case dark
        case light
        case highContrast
    }

    public enum PrivacyClass: String, Codable, Sendable {
        case syntheticPublic = "synthetic-public"
        case privateLocal = "private-local"
        case prohibited
    }

    public enum EvidenceClass: String, Codable, Sendable {
        case implemented
        case fixtureProjection = "fixture-projection"
        case scaffoldedGap = "scaffolded-gap"
    }

    public let id: String
    public let captureVariant: String
    public let outputFile: String
    public let platform: Platform
    public let surface: String
    public let fixture: String
    public let viewport: String
    public let appearance: Appearance
    public let differentiateWithoutColor: Bool
    public let reduceMotion: Bool
    public let textScale: String
    public let activeWindow: Bool
    public let locale: String
    public let expectedAccessibilityLabels: [String]
    public let privacyClass: PrivacyClass
    public let evidenceClass: EvidenceClass

    public init(
        id: String,
        captureVariant: String,
        outputFile: String,
        platform: Platform,
        surface: String,
        fixture: String,
        viewport: String,
        appearance: Appearance,
        differentiateWithoutColor: Bool = false,
        reduceMotion: Bool = false,
        textScale: String = "standard",
        activeWindow: Bool = true,
        locale: String = "en_US",
        expectedAccessibilityLabels: [String] = [],
        privacyClass: PrivacyClass = .syntheticPublic,
        evidenceClass: EvidenceClass
    ) {
        self.id = id
        self.captureVariant = captureVariant
        self.outputFile = outputFile
        self.platform = platform
        self.surface = surface
        self.fixture = fixture
        self.viewport = viewport
        self.appearance = appearance
        self.differentiateWithoutColor = differentiateWithoutColor
        self.reduceMotion = reduceMotion
        self.textScale = textScale
        self.activeWindow = activeWindow
        self.locale = locale
        self.expectedAccessibilityLabels = expectedAccessibilityLabels
        self.privacyClass = privacyClass
        self.evidenceClass = evidenceClass
    }
}
