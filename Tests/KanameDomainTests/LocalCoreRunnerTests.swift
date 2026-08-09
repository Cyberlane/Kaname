import Foundation
import Testing
@testable import KanameLocalCore

struct LocalCoreRunnerTests {
    @Test
    func decodesBoundedRedactedLocalCoreReport() throws {
        let report = try LocalCoreRunner.decodeScenarioReport(Data("""
        {"fixture_id":"F-01","task_state":"accepted","attention":"none","health":"ready","effect_count":1,"event_count":9,"unsupported_event_count":5}
        """.utf8))

        #expect(report.fixtureID == "F-01")
        #expect(report.taskState == "accepted")
        #expect(report.health == "ready")
        #expect(report.effectCount == 1)
    }

    @Test
    func rejectsAReportThatIsNotAPhaseOneFixture() {
        #expect(throws: LocalCoreRunnerError.malformedReport) {
            try LocalCoreRunner.decodeScenarioReport(Data("{}".utf8))
        }
    }

    @Test
    func decodesOnlyOrderedEventAppendReceipts() throws {
        let receipt = try LocalCoreRunner.decodeEventAppendReport(Data("""
        {"event_id":"codex-run-001-7","stream_id":"thread:project:kaname:thread-001","store_position":4,"stream_sequence":2,"duplicate":false}
        """.utf8))

        #expect(receipt.eventID == "codex-run-001-7")
        #expect(receipt.storePosition == 4)
        #expect(receipt.streamSequence == 2)
        #expect(!receipt.duplicate)

        #expect(throws: LocalCoreRunnerError.malformedAppendReport) {
            try LocalCoreRunner.decodeEventAppendReport(Data("{}".utf8))
        }
    }
}
