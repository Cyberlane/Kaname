import Foundation
import Testing
import KanameProtocol
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

    @Test
    func decodesOnlyIdentifiedMobileAuthorityReceipts() throws {
        var enrollment = Kaname_V1_DeviceEnrollmentReceipt()
        enrollment.enrollmentID = "enrollment-1"
        enrollment.deviceID = "iphone-justin"
        enrollment.state = .active
        enrollment.reasonCode = "enrollment_activated"
        let decodedEnrollment = try LocalCoreRunner.decodeEnrollmentReceipt(
            enrollment.serializedData()
        )
        #expect(decodedEnrollment.state == .active)

        var sync = Kaname_V1_SyncReceipt()
        sync.envelopeID = "envelope-1"
        sync.senderDeviceID = "iphone-justin"
        sync.senderSequence = 1
        sync.state = .decrypted
        sync.reasonCode = "authenticated_envelope_recorded"
        let decodedSync = try LocalCoreRunner.decodeSyncReceipt(sync.serializedData())
        #expect(decodedSync.state == .decrypted)

        #expect(throws: LocalCoreRunnerError.malformedAppendReport) {
            try LocalCoreRunner.decodeEnrollmentReceipt(Data())
        }
        #expect(throws: LocalCoreRunnerError.malformedAppendReport) {
            try LocalCoreRunner.decodeSyncReceipt(Data())
        }
    }
}
