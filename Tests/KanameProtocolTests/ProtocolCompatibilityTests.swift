import Foundation
import Testing
import KanameProtocol
import SwiftProtobuf

struct ProtocolCompatibilityTests {
    @Test
    func swiftGeneratedWireMatchesItsCheckedInGoldenVector() throws {
        let expected = try fixture("swift-event-envelope.bin")
        #expect(try eventFixture().serializedData() == expected)
    }

    @Test
    func swiftDecodesAndReencodesTheRustGoldenVector() throws {
        let expected = try fixture("rust-event-envelope.bin")
        let event = try Kaname_V1_EventEnvelope(serializedBytes: expected)

        #expect(event.eventID == "event-schema-vector-001")
        #expect(event.payload.typeURL == "kaname.event.future.unsupported.v9")
        #expect(event.payload.value == Data([0x08, 0x96, 0x01]))
        #expect(try event.serializedData() == expected)
    }

    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: root.appending(path: "Fixtures/wire/v1/\(name)"))
    }

    private func eventFixture() -> Kaname_V1_EventEnvelope {
        var schemaVersion = Kaname_V1_SchemaVersion()
        schemaVersion.major = 1

        var payload = Kaname_V1_OpaqueTypedPayload()
        payload.typeURL = "kaname.event.future.unsupported.v9"
        payload.contentType = "application/x-protobuf"
        payload.value = Data([0x08, 0x96, 0x01])
        payload.payloadVersion = 9

        var provenance = Kaname_V1_EventProvenance()
        provenance.sourceKind = "fake_provider"
        provenance.providerInstanceID = "fake-local"
        provenance.nativeType = "fake.v1.unknown.extension"
        provenance.nativeCursor = Data("cursor-unknown-1".utf8)
        provenance.rawEvidenceDigest = "sha256:synthetic-vector"
        provenance.retentionClass = .sevenDays

        var event = Kaname_V1_EventEnvelope()
        event.schemaVersion = schemaVersion
        event.eventID = "event-schema-vector-001"
        event.storePosition = 42
        event.streamID = "thread-schema-vector-001"
        event.streamSequence = 7
        event.occurredAtUnixMillis = 1_762_000_000_000
        event.kind = "provider.native_event_observed"
        event.payload = payload
        event.provenance = provenance
        event.causationID = "command-schema-vector-001"
        event.correlationID = "task-schema-vector-001"
        return event
    }
}
