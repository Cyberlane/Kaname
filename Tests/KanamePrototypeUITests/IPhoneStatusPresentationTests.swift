import KanameDesignSystem
import XCTest
@testable import KanamePrototypeUI

final class IPhoneStatusPresentationTests: XCTestCase {
    func testDeliveryStatusMappingsAreExhaustive() {
        let expected: [IPhoneDeliveryStatus: (KanameStatusTone, String)] = [
            .active: (.active, "waveform.path.ecg"),
            .ready: (.success, "checkmark.circle.fill"),
            .needsDecision: (.attention, "checkmark.shield"),
            .research: (.active, "text.magnifyingglass"),
            .paused: (.neutral, "pause.circle"),
        ]

        XCTAssertEqual(Set(expected.keys), Set(IPhoneDeliveryStatus.allCases))
        for status in IPhoneDeliveryStatus.allCases {
            guard let mapping = expected[status] else {
                XCTFail("Missing delivery mapping for \(status.rawValue)")
                continue
            }
            XCTAssertEqual(status.presentation.label, status.rawValue)
            XCTAssertEqual(status.presentation.tone, mapping.0)
            XCTAssertEqual(status.presentation.symbolName, mapping.1)
            XCTAssertEqual(status.presentation.accessibilityLabel, "Status: \(status.rawValue)")
        }
    }

    func testCheckStatusMappingsAreExhaustive() {
        let expected: [IPhoneCheckStatus: (KanameStatusTone, String)] = [
            .passed: (.success, "checkmark.circle.fill"),
            .oneFailed: (.danger, "xmark.octagon.fill"),
            .fourChecksPassed: (.success, "checkmark.circle.fill"),
            .allChecksPassed: (.success, "checkmark.circle.fill"),
            .lastRunPassed: (.success, "checkmark.circle.fill"),
            .planningBoundary: (.informational, "info.circle.fill"),
            .gateReview: (.attention, "eye.circle"),
        ]

        XCTAssertEqual(Set(expected.keys), Set(IPhoneCheckStatus.allCases))
        for status in IPhoneCheckStatus.allCases {
            guard let mapping = expected[status] else {
                XCTFail("Missing check mapping for \(status.rawValue)")
                continue
            }
            XCTAssertEqual(status.presentation.label, status.rawValue)
            XCTAssertEqual(status.presentation.tone, mapping.0)
            XCTAssertEqual(status.presentation.symbolName, mapping.1)
            XCTAssertEqual(status.presentation.accessibilityLabel, "Status: \(status.rawValue)")
        }
    }

    func testSessionStatusMappingsAreExhaustiveAndLabelStableStatesConsistently() {
        let expected: [IPhoneSessionStatus: KanameStatusTone] = [
            .running: .active,
            .needsStart: .attention,
            .paused: .neutral,
            .ready: .success,
            .active: .active,
            .manual: .neutral,
            .scheduled: .active,
            .protected: .attention,
            .fixture: .external,
            .enabled: .success,
        ]

        XCTAssertEqual(Set(expected.keys), Set(IPhoneSessionStatus.allCases))
        for status in IPhoneSessionStatus.allCases {
            XCTAssertEqual(status.presentation.label, status.rawValue)
            XCTAssertEqual(status.presentation.tone, expected[status])
            XCTAssertFalse(status.presentation.symbolName.isEmpty)
            XCTAssertEqual(status.presentation.accessibilityLabel, "Status: \(status.rawValue)")
        }
    }

    func testCIStatusMappingsAreExhaustive() {
        let expected: [IPhoneCIStatus: (KanameStatusTone, String)] = [
            .oneFailure: (.danger, "xmark.octagon.fill"),
            .healthy: (.success, "checkmark.circle.fill"),
            .noRun: (.neutral, "circle"),
            .notApplicable: (.neutral, "minus.circle"),
        ]

        XCTAssertEqual(Set(expected.keys), Set(IPhoneCIStatus.allCases))
        for status in IPhoneCIStatus.allCases {
            guard let mapping = expected[status] else {
                XCTFail("Missing CI mapping for \(status.rawValue)")
                continue
            }
            XCTAssertEqual(status.presentation.label, status.rawValue)
            XCTAssertEqual(status.presentation.tone, mapping.0)
            XCTAssertEqual(status.presentation.symbolName, mapping.1)
            XCTAssertEqual(status.presentation.accessibilityLabel, "Status: \(status.rawValue)")
        }
    }

    func testRetryStatusUsesApprovalSpecificAccessibilityLanguage() {
        XCTAssertEqual(
            Set(IPhoneRetryStatus.allCases),
            Set([IPhoneRetryStatus.noRetryNeeded, .retryNeedsApproval])
        )
        XCTAssertEqual(IPhoneRetryStatus.noRetryNeeded.presentation.tone, .success)
        XCTAssertEqual(IPhoneRetryStatus.noRetryNeeded.presentation.symbolName, "checkmark.circle.fill")
        XCTAssertEqual(
            IPhoneRetryStatus.noRetryNeeded.presentation.accessibilityLabel,
            "Status: No retry needed"
        )
        XCTAssertEqual(IPhoneRetryStatus.retryNeedsApproval.presentation.tone, .attention)
        XCTAssertEqual(IPhoneRetryStatus.retryNeedsApproval.presentation.symbolName, "checkmark.shield")
        XCTAssertEqual(
            IPhoneRetryStatus.retryNeedsApproval.presentation.accessibilityLabel,
            "Approval required: Retry needs approval"
        )
    }

    func testMetadataMappingsStayNeutralAndExposeStableSymbols() {
        let expected: [IPhoneMetadataKind: (String, String)] = [
            .changedFiles: ("doc.on.doc", "Changed files: 3 files changed"),
            .sessions: ("cpu", "Sessions: 2"),
            .logs: ("doc.text", "Logs"),
            .workflow: ("arrow.triangle.branch", "Workflow"),
        ]
        let labels: [IPhoneMetadataKind: String] = [
            .changedFiles: "3 files changed",
            .sessions: "2",
            .logs: "Logs",
            .workflow: "Workflow",
        ]

        XCTAssertEqual(Set(expected.keys), Set(IPhoneMetadataKind.allCases))
        for kind in IPhoneMetadataKind.allCases {
            guard let label = labels[kind], let mapping = expected[kind] else {
                XCTFail("Missing metadata mapping for \(kind.rawValue)")
                continue
            }
            let presentation = kind.presentation(label: label)
            XCTAssertEqual(presentation.label, label)
            XCTAssertEqual(presentation.symbolName, mapping.0)
            XCTAssertEqual(presentation.accessibilityLabel, mapping.1)
        }
    }

    func testWireLookupPreservesUnknownVisibleCopyWithoutInventingSuccess() {
        let unknown = IPhoneCIStatus.presentation(for: "Delayed by provider")

        XCTAssertEqual(unknown.label, "Delayed by provider")
        XCTAssertEqual(unknown.tone, .neutral)
        XCTAssertEqual(unknown.symbolName, "questionmark.circle")
        XCTAssertEqual(unknown.accessibilityLabel, "Status: Delayed by provider")
    }
}
