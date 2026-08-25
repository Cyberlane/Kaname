import Foundation
import XCTest
@testable import KanameDesignSystem

final class KanameDesignSystemTests: XCTestCase {
    private struct ScenarioManifest: Decodable {
        let schemaVersion: Int
        let privacyClass: String
        let scenarios: [KanameDesignScenario]
    }

    func testHexColorDecoding() throws {
        let color = try XCTUnwrap(KanameRGBColor(hex: "#88C0D0"))
        XCTAssertEqual(color.red, 136.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(color.green, 192.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(color.blue, 208.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(color.alpha, 1)
        XCTAssertNil(KanameRGBColor(hex: "not-a-color"))
    }

    func testSpacingScaleIsStrictlyIncreasing() {
        let values = [
            KanameSpacing.hairline,
            KanameSpacing.xSmall,
            KanameSpacing.small,
            KanameSpacing.medium,
            KanameSpacing.large,
            KanameSpacing.xLarge,
            KanameSpacing.xxLarge,
            KanameSpacing.xxxLarge,
            KanameSpacing.huge,
        ]
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(Set(values).count, values.count)
    }

    func testEveryStatusToneHasNonColorMeaning() {
        for tone in KanameStatusTone.allCases {
            XCTAssertFalse(tone.symbolName.isEmpty)
            XCTAssertFalse(tone.rawValue.isEmpty)
        }
        XCTAssertEqual(Set(KanameStatusTone.allCases.map(\.symbolName)).count, KanameStatusTone.allCases.count)
    }

    func testAuthorityAndReceiptStatesAreTyped() {
        XCTAssertTrue(KanameApprovalState.proposed.acceptsDecision)
        XCTAssertFalse(KanameApprovalState.working.acceptsDecision)
        XCTAssertFalse(KanameApprovalState.changesRequested.acceptsDecision)
        XCTAssertEqual(KanameApprovalState.changesRequested.label, "Changes requested")
        XCTAssertEqual(KanameApprovalState.outcomeUncertain.tone, .warning)
        for state in [
            KanameReceiptState.localStored,
            .queued,
            .gatewayAccepted,
            .published,
            .delivered,
            .failed,
            .outcomeUncertain,
        ] {
            XCTAssertFalse(state.tone.symbolName.isEmpty)
            XCTAssertFalse(state.label.isEmpty)
        }
        XCTAssertEqual(KanameReceiptState.localStored.label, "Stored locally")
        XCTAssertEqual(KanameReceiptState.gatewayAccepted.label, "Received by host")
    }

    func testInteractiveTargetMeetsAppleMinimum() {
        XCTAssertGreaterThanOrEqual(KanameSize.minimumInteractiveTarget, 44)
    }

    func testVersionAndScenarioManifestDecode() throws {
        XCTAssertEqual(KanameDesignSystemMetadata.schemaVersion, 1)
        XCTAssertTrue(KanameDesignSystemMetadata.version.hasPrefix("0."))
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("Fixtures/design-system/catalog-scenarios.json"))
        let manifest = try JSONDecoder().decode(ScenarioManifest.self, from: data)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.privacyClass, "synthetic-public")
        XCTAssertEqual(manifest.scenarios.count, 7)
        XCTAssertTrue(manifest.scenarios.allSatisfy { $0.privacyClass == .syntheticPublic })

        let productData = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("Fixtures/design-system/product-scenarios.json"))
        let productManifest = try JSONDecoder().decode(ScenarioManifest.self, from: productData)
        let expectedProductScenarioIDs: Set<String> = [
            "desktop-github-statuses",
            "desktop-home-statuses",
            "desktop-home-statuses-large-text",
            "desktop-link-host",
            "desktop-link-publication-statuses",
            "ios-home-synthetic",
            "ios-project-github-statuses",
            "ios-project-github-statuses-large-text",
            "link-macos-synthetic",
            "link-macos-synthetic-large-text",
        ]
        XCTAssertEqual(productManifest.scenarios.count, 10)
        XCTAssertEqual(Set(productManifest.scenarios.map(\.id)), expectedProductScenarioIDs)
        XCTAssertEqual(
            Set(productManifest.scenarios.map(\.outputFile)).count,
            productManifest.scenarios.count
        )
        XCTAssertTrue(productManifest.scenarios.allSatisfy { $0.evidenceClass == .fixtureProjection })
    }
}
