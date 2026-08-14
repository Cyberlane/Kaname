import Foundation
import KanameDesktop
import KanameProtocol
import Testing

@Suite
struct DesktopWorkflowV2LibraryTests {
    @Test
    func portfolioHistoryContentAndComparisonPreserveTheRustPresentationContract() async throws {
        let transport = WorkflowLibraryFixtureTransport()
        let client = DesktopWorkflowV2LibraryClient(transport: transport)

        let portfolio = try await client.portfolio(requestID: "portfolio:fixture")
        #expect(portfolio.count == 1)
        #expect(portfolio[0].state == .active)
        #expect(portfolio[0].hasDraft)
        #expect(portfolio[0].latestRevisionNumber == 2)
        #expect(portfolio[0].activeRevisionID == "revision-one")
        #expect(portfolio[0].executionSupport == .unsupported)

        let history = try await client.revisionHistory(
            workflowID: "workflow-one",
            requestID: "history:fixture"
        )
        #expect(history.map(\.revisionNumber) == [2, 1])
        #expect(history.map(\.isActive) == [false, true])

        let revision = try await client.revision(
            revisionID: "revision-one",
            requestID: "revision:fixture"
        )
        #expect(revision.summary.revisionNumber == 1)
        #expect(String(decoding: revision.workflowJSON, as: UTF8.self).contains("workflow-one"))
        #expect(String(decoding: revision.layoutJSON, as: UTF8.self).contains("nodes"))

        let comparison = try await client.compare(
            fromRevisionID: "revision-one",
            toRevisionID: "revision-two",
            requestID: "comparison:fixture"
        )
        #expect(comparison.changedDefinitionPointers == ["/summary"])
        #expect(comparison.changedLayoutPointers == ["/nodes/0/x"])
        #expect(comparison.changedConfigurationPointers == ["/properties"])
        #expect(!comparison.truncated)

        let queries = await transport.recordedQueries()
        #expect(queries.count == 4)
        #expect(queries.allSatisfy { $0.schemaVersion.major == 1 })
        #expect(queries.allSatisfy { !$0.requestID.isEmpty })
    }

    @Test
    func activationKeepsDisableDistinctAndRejectsAMismatchedReceipt() async throws {
        let transport = WorkflowLibraryFixtureTransport()
        let client = DesktopWorkflowV2LibraryClient(transport: transport)
        let active = try await client.setActivation(
            aliasID: "primary-alias",
            workflowID: "workflow-one",
            revisionID: "revision-one",
            expectedGeneration: 0,
            updatedAtUnixMillis: 50,
            requestID: "activate:fixture"
        )
        #expect(active.revisionID == "revision-one")
        #expect(active.generation == 1)

        let disabled = try await client.setActivation(
            aliasID: "primary-alias",
            workflowID: "workflow-one",
            revisionID: nil,
            expectedGeneration: 1,
            updatedAtUnixMillis: 51,
            requestID: "disable:fixture"
        )
        #expect(disabled.revisionID == nil)
        #expect(disabled.generation == 2)
        let requests = await transport.recordedActivations()
        #expect(requests[0].revisionID == "revision-one")
        #expect(requests[1].revisionID.isEmpty)

        await transport.returnMismatchedRequestID()
        await #expect(throws: DesktopWorkflowV2LibraryError.malformedResponse) {
            _ = try await client.portfolio(requestID: "expected:fixture")
        }
    }
}

private actor WorkflowLibraryFixtureTransport: DesktopWorkflowLibraryTransport {
    private var queries: [Kaname_V1_WorkflowLibraryQueryRequest] = []
    private var activations: [Kaname_V1_SetWorkflowActivationRequest] = []
    private var mismatchesRequestID = false

    func queryWorkflowLibrary(
        _ request: Kaname_V1_WorkflowLibraryQueryRequest,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_WorkflowLibraryQueryResponse {
        queries.append(request)
        var response = Kaname_V1_WorkflowLibraryQueryResponse()
        response.schemaVersion = schemaVersion
        response.requestID = mismatchesRequestID ? "different:request" : request.requestID
        switch request.query {
        case .portfolio:
            response.portfolio = [portfolioItem]
        case .revisionHistory:
            response.revisionHistory = [revisionSummary(number: 2), revisionSummary(number: 1)]
        case .revisionContent:
            var content = Kaname_V1_WorkflowRevisionContent()
            content.summary = revisionSummary(number: 1)
            content.workflowJson = Data(#"{"workflowId":"workflow-one"}"#.utf8)
            content.layoutJson = Data(#"{"nodes":[]}"#.utf8)
            content.configurationJson = Data(#"{"type":"object"}"#.utf8)
            content.compiledJson = Data(#"{"nodes":[]}"#.utf8)
            response.revisionContent = content
        case .revisionComparison:
            var comparison = Kaname_V1_WorkflowRevisionComparison()
            comparison.workflowID = "workflow-one"
            comparison.fromRevisionID = "revision-one"
            comparison.toRevisionID = "revision-two"
            comparison.changedDefinitionPointers = ["/summary"]
            comparison.changedLayoutPointers = ["/nodes/0/x"]
            comparison.changedConfigurationPointers = ["/properties"]
            response.revisionComparison = comparison
        case nil:
            break
        }
        return response
    }

    func setWorkflowActivation(
        _ request: Kaname_V1_SetWorkflowActivationRequest,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_SetWorkflowActivationResponse {
        activations.append(request)
        var response = Kaname_V1_SetWorkflowActivationResponse()
        response.schemaVersion = schemaVersion
        response.requestID = request.requestID
        response.workflowID = request.workflowID
        response.aliasKey = request.aliasKey
        response.revisionID = request.revisionID
        response.generation = request.expectedGeneration + 1
        return response
    }

    func recordedQueries() -> [Kaname_V1_WorkflowLibraryQueryRequest] { queries }
    func recordedActivations() -> [Kaname_V1_SetWorkflowActivationRequest] { activations }
    func returnMismatchedRequestID() { mismatchesRequestID = true }

    private var portfolioItem: Kaname_V1_WorkflowPortfolioItem {
        var item = Kaname_V1_WorkflowPortfolioItem()
        item.workflowID = "workflow-one"
        item.packageID = "dev.kaname.workflow-one"
        item.name = "Workflow one"
        item.summary = "Synthetic"
        item.state = .active
        item.draftPresent = true
        item.latestRevisionID = "revision-two"
        item.latestRevisionNumber = 2
        item.activeRevisionID = "revision-one"
        item.executionSupport = .unsupported
        return item
    }

    private func revisionSummary(number: Int64) -> Kaname_V1_WorkflowRevisionSummary {
        var summary = Kaname_V1_WorkflowRevisionSummary()
        summary.workflowID = "workflow-one"
        summary.revisionID = "revision-\(number == 1 ? "one" : "two")"
        summary.revisionNumber = number
        summary.releaseVersion = "1.\(number - 1).0"
        summary.createdAtUnixMillis = 20 + number
        summary.packageDigest = String(repeating: number == 1 ? "a" : "b", count: 64)
        summary.isActive = number == 1
        summary.executionSupport = .unsupported
        return summary
    }

    private var schemaVersion: Kaname_V1_SchemaVersion {
        var version = Kaname_V1_SchemaVersion()
        version.major = 1
        return version
    }
}
