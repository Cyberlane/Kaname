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
}
