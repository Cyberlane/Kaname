import Testing
@testable import KanameDesktop

@MainActor
enum DesktopWorkflowTestSupport {
    static func install(
        _ manifest: DesktopWorkflowPackageManifest,
        into model: DesktopAppModel
    ) throws {
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: [], enable: true
        )
    }

    static func prepareRun(
        model: DesktopAppModel,
        workflowID: String,
        nonce: String
    ) throws -> (workItemID: String, episodeID: String, runID: String) {
        let workItemID = try #require(model.createWorkflowWorkItem(
            workflowID: workflowID, title: "Fixture", goal: "Exercise workflow operations"
        ))
        let eventID = try #require(model.observeWorkflowExternalEvent(
            source: "manual", accountID: "local", conversationID: nil, messageID: nil,
            cursor: nil, payloadDigest: "fixture", deduplicationKey: "fixture-\(workflowID)-\(nonce)"
        ))
        let episodeID = try #require(model.createWorkflowEpisode(
            workItemID: workItemID, sourceEventID: eventID, sourceMessageID: nil,
            intent: .request, summary: "Fixture", deltaSummary: "Initial"
        ))
        let contextID = try #require(model.compileWorkflowContext(
            workItemID: workItemID, episodeID: episodeID, request: "Run fixture", references: []
        ))
        let runID = try #require(model.queueWorkflowRun(
            workItemID: workItemID, episodeID: episodeID, contextSnapshotID: contextID
        ))
        return (workItemID, episodeID, runID)
    }
}
