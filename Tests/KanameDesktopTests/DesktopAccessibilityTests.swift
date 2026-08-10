import XCTest
@testable import KanameDesktop

final class DesktopAccessibilityTests: XCTestCase {
    func testComposerFocusRequestsNormalizeThreadAndAdvanceGeneration() {
        let first = DesktopComposerFocusRequest.next(after: nil, threadID: "  thread-one  ")
        let second = DesktopComposerFocusRequest.next(after: first, threadID: "thread-one")

        XCTAssertEqual(first, DesktopComposerFocusRequest(threadID: "thread-one", generation: 1))
        XCTAssertEqual(second, DesktopComposerFocusRequest(threadID: "thread-one", generation: 2))
    }

    func testComposerFocusRequestRejectsEmptyThreadIdentifier() {
        XCTAssertNil(DesktopComposerFocusRequest.next(after: nil, threadID: " \n "))
    }

    func testStandardSheetMetricsStayWithinCompactDesktopHeight() {
        let metrics = DesktopAccessibleSheetMetrics.adaptive(
            idealWidth: 650,
            idealHeight: 700,
            usesAccessibilityTextSize: false
        )

        XCTAssertEqual(metrics.idealWidth, 650)
        XCTAssertEqual(metrics.idealHeight, 620)
        XCTAssertEqual(metrics.maximumHeight, 660)
        XCTAssertLessThanOrEqual(metrics.maximumWidth, 920)
    }

    func testAccessibilityTextMetricsPreferScrollingAndExpansionRoom() {
        let metrics = DesktopAccessibleSheetMetrics.adaptive(
            idealWidth: 540,
            idealHeight: 700,
            usesAccessibilityTextSize: true
        )

        XCTAssertEqual(metrics.minimumWidth, 380)
        XCTAssertEqual(metrics.idealHeight, 560)
        XCTAssertEqual(metrics.maximumHeight, 640)
        XCTAssertGreaterThan(metrics.maximumWidth, metrics.idealWidth)
    }

    func testWidthOnlySheetDoesNotInventVerticalConstraints() {
        let metrics = DesktopAccessibleSheetMetrics.adaptive(
            idealWidth: 440,
            usesAccessibilityTextSize: true
        )

        XCTAssertNil(metrics.minimumHeight)
        XCTAssertNil(metrics.idealHeight)
        XCTAssertNil(metrics.maximumHeight)
    }
}
