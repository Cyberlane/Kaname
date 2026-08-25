#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import KanameDesignSystem

final class KanameSyntheticTextScaleTests: XCTestCase {
    func testSyntheticTextScaleContractIsStableAndConspicuous() {
        XCTAssertEqual(KanameSyntheticTextScale.allCases, [.standard, .accessibility3])
        XCTAssertEqual(KanameSyntheticTextScale.standard.fontScaleFactor, 1)
        XCTAssertGreaterThan(KanameSyntheticTextScale.accessibility3.fontScaleFactor, 1)
        XCTAssertEqual(
            KanameAccessibilityPreferences(syntheticTextScale: .accessibility3)
                .syntheticTextScale,
            .accessibility3
        )
    }

    @MainActor
    func testAccessibility3SemanticFontChangesRenderedPixelsAndLayout() throws {
        let standard = try renderSemanticText(scale: .standard)
        let accessibility = try renderSemanticText(scale: .accessibility3)

        XCTAssertGreaterThan(accessibility.size.height, standard.size.height)
        XCTAssertGreaterThan(accessibility.size.width, standard.size.width)
        XCTAssertNotEqual(accessibility.pngData, standard.pngData)
    }

    @MainActor
    private func renderSemanticText(
        scale: KanameSyntheticTextScale
    ) throws -> (size: CGSize, pngData: Data) {
        let content = Text("Kaname status")
            .kanameSemanticFont(.body)
            .fixedSize()
            .padding(8)
            .environment(
                \.kanameAccessibilityPreferences,
                KanameAccessibilityPreferences(syntheticTextScale: scale)
            )
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let pngData = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        return (image.size, pngData)
    }
}
#endif
