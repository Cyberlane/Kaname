import Foundation
import KanameProtocol
import SwiftProtobuf

@main
enum KanameProtocolFixtureTool {
    static func main() throws {
        let encoded = try eventFixture().serializedData()
        FileHandle.standardOutput.write(encoded)
    }

    static func eventFixture() -> Kaname_V1_EventEnvelope {
        var schemaVersion = Kaname_V1_SchemaVersion()
        schemaVersion.major = 1
        schemaVersion.minor = 0

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
