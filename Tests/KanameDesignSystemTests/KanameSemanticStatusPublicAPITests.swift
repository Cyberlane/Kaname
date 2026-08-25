import SwiftUI
import XCTest
import KanameDesignSystem

final class KanameSemanticStatusPublicAPITests: XCTestCase {
    func testStatusPresentationPreservesPublicValueSemantics() {
        let presentation = KanameStatusPresentation(
            label: "Needs review",
            tone: .attention,
            symbolName: "eye.fill",
            accessibilityLabel: "Status: needs review"
        )

        XCTAssertEqual(presentation.label, "Needs review")
        XCTAssertEqual(presentation.tone, .attention)
        XCTAssertEqual(presentation.symbolName, "eye.fill")
        XCTAssertEqual(presentation.accessibilityLabel, "Status: needs review")
        XCTAssertEqual(
            presentation,
            KanameStatusPresentation(
                label: "Needs review",
                tone: .attention,
                symbolName: "eye.fill",
                accessibilityLabel: "Status: needs review"
            )
        )
    }

    func testContrastResolutionCombinesNativeAndDeterministicPreferences() {
        XCTAssertEqual(
            KanameContrastResolution.resolve(
                nativeColorSchemeContrast: .standard,
                accessibilityPreferences: .system
            ),
            .standard
        )
        XCTAssertEqual(
            KanameContrastResolution.resolve(
                nativeColorSchemeContrast: .increased,
                accessibilityPreferences: .system
            ),
            .increased
        )
        XCTAssertEqual(
            KanameContrastResolution.resolve(
                nativeColorSchemeContrast: .standard,
                accessibilityPreferences: KanameAccessibilityPreferences(increasedContrast: true)
            ),
            .increased
        )
        XCTAssertEqual(
            KanameContrastResolution.resolve(
                nativeColorSchemeContrast: .increased,
                accessibilityPreferences: KanameAccessibilityPreferences(increasedContrast: true)
            ),
            .increased
        )
    }

    @MainActor
    func testBadgeDensitiesAndPublicInitializersAreAvailable() {
        XCTAssertEqual(KanameBadgeDensity.allCases, [.compact, .regular])

        let presentation = KanameStatusPresentation(
            label: "Queued",
            tone: .active,
            symbolName: "clock.fill",
            accessibilityLabel: "Delivery status: queued"
        )
        _ = KanameStatusBadge(presentation, density: .compact)
        _ = KanameStatusBadge("Queued", tone: .active)
        _ = KanameMetadataChip(
            "Synthetic-public",
            symbolName: "sparkles",
            accessibilityLabel: "Data classification: synthetic-public",
            density: .regular
        )
        _ = KanameMessageBubble(
            author: "Synthetic host",
            body: "Synthetic message",
            role: .host,
            participantPresentation: .init(
                label: "Host",
                tone: .informational,
                symbolName: "person.fill",
                accessibilityLabel: "Participant: Host"
            ),
            receipt: .init(state: .published),
            receiptPresentation: .init(
                label: "Published by host",
                tone: .external,
                symbolName: "arrow.up.right.circle.fill",
                accessibilityLabel: "Message status: Published by host"
            )
        )
    }

    func testMessageDefaultsExposeNonColorParticipantAndReceiptLanguage() {
        XCTAssertEqual(KanameMessageParticipantRole.host.presentation.accessibilityLabel, "Participant: Host")
        XCTAssertEqual(
            KanameMessageParticipantRole.collaborator.presentation.accessibilityLabel,
            "Participant: External collaborator"
        )
        XCTAssertEqual(
            KanameMessageReceipt(state: .gatewayAccepted).presentation.accessibilityLabel,
            "Message status: Received by host"
        )
        XCTAssertEqual(
            KanameMessageReceipt(state: .published).presentation.accessibilityLabel,
            "Message status: Published by host"
        )
    }

    func testDesignSystemVersionIsZeroPointTwo() {
        XCTAssertEqual(KanameDesignSystemMetadata.version, "0.2.0")
    }
}
