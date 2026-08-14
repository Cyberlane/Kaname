import Foundation
import KanameProtocol
import SwiftProtobuf
import Testing

struct WorkflowProtocolContractTests {
    @Test
    func diagnosticLocationsAndArtifactDigestsRoundTripExactly() throws {
        var start = Kaname_V1_WorkflowSourcePosition()
        start.byteOffset = 18
        start.line = 2
        start.column = 4
        var end = Kaname_V1_WorkflowSourcePosition()
        end.byteOffset = 29
        end.line = 2
        end.column = 15
        var location = Kaname_V1_WorkflowSourceLocation()
        location.sourceID = "manifest.json"
        location.jsonPointer = "/graph/nodes/0"
        location.start = start
        location.end = end
        var diagnostic = Kaname_V1_WorkflowDiagnostic()
        diagnostic.code = "workflow.node.type_unknown"
        diagnostic.severity = .error
        diagnostic.summary = "The node type is not registered."
        diagnostic.instancePointer = "/graph/nodes/0/type"
        diagnostic.schemaPointer = "/properties/type/enum"
        diagnostic.location = location
        var digests = Kaname_V1_WorkflowArtifactDigests()
        digests.definitionDigest = "sha256:definition"
        digests.layoutDigest = "sha256:layout"
        digests.schemaBundleDigest = "sha256:schema"
        digests.dependencyLockDigest = "sha256:dependencies"
        digests.configurationContractDigest = "sha256:configuration"
        digests.compiledArtifactDigest = "sha256:artifact"
        var response = Kaname_V1_CompileWorkflowResponse()
        response.schemaVersion = schemaVersion()
        response.requestID = "compile:synthetic-001"
        response.outcome = .invalid
        response.diagnostics = [diagnostic]
        response.digests = digests

        let decoded = try Kaname_V1_CompileWorkflowResponse(
            serializedBytes: response.serializedData()
        )
        #expect(decoded == response)
        #expect(decoded.diagnostics[0].location.start.byteOffset == 18)
        #expect(decoded.diagnostics[0].location.end.column == 15)
        #expect(decoded.digests.compiledArtifactDigest == "sha256:artifact")
    }

    @Test
    func swiftPreservesAFutureUnknownRequestField() throws {
        var request = Kaname_V1_ValidateWorkflowRequest()
        request.schemaVersion = schemaVersion()
        request.requestID = "validate:synthetic-001"
        request.schemaJson = Data(#"{"type":"object"}"#.utf8)
        request.instanceJson = Data(#"{"name":"Synthetic"}"#.utf8)
        request.maximumDiagnostics = 64
        var futureWire = try request.serializedData()
        futureWire.append(contentsOf: [0xa0, 0x06, 0x01])

        let decoded = try Kaname_V1_ValidateWorkflowRequest(serializedBytes: futureWire)
        #expect(decoded.requestID == request.requestID)
        #expect(decoded.maximumDiagnostics == 64)
        #expect(try decoded.serializedData() == futureWire)
    }

    @Test
    func malformedWireFailsWithoutProducingAPartialRequest() {
        #expect(throws: (any Error).self) {
            _ = try Kaname_V1_CompileWorkflowRequest(serializedBytes: [0x0a])
        }
    }

    @Test
    func clientRequestIDPreflightMatchesTheIngressCharacterContract() {
        #expect(WorkflowProtocolClientPreflight.acceptsRequestID("compile:job_1.2-alpha"))
        #expect(!WorkflowProtocolClientPreflight.acceptsRequestID(""))
        #expect(!WorkflowProtocolClientPreflight.acceptsRequestID("contains space"))
        #expect(!WorkflowProtocolClientPreflight.acceptsRequestID("日本語"))
        #expect(WorkflowProtocolClientPreflight.acceptsRequestID(String(repeating: "a", count: 128)))
        #expect(!WorkflowProtocolClientPreflight.acceptsRequestID(String(repeating: "a", count: 129)))
    }

    private func schemaVersion() -> Kaname_V1_SchemaVersion {
        var version = Kaname_V1_SchemaVersion()
        version.major = 1
        return version
    }
}
