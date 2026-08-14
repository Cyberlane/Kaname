import Foundation
import KanameLocalCore
import KanameProtocol

public protocol DesktopWorkflowLibraryTransport: Sendable {
    func queryWorkflowLibrary(
        _ request: Kaname_V1_WorkflowLibraryQueryRequest,
        timeout: TimeInterval
    ) async throws -> Kaname_V1_WorkflowLibraryQueryResponse

    func setWorkflowActivation(
        _ request: Kaname_V1_SetWorkflowActivationRequest,
        timeout: TimeInterval
    ) async throws -> Kaname_V1_SetWorkflowActivationResponse
}

extension LocalCoreRunner: DesktopWorkflowLibraryTransport {}

public enum DesktopWorkflowV2LibraryError: Error, Equatable, Sendable {
    case invalidRequest
    case malformedResponse
}

public enum DesktopWorkflowV2PortfolioState: String, Equatable, Sendable {
    case draft
    case published
    case active
    case disabled
}

public enum DesktopWorkflowV2ExecutionSupport: String, Equatable, Sendable {
    case executable
    case unsupported
}

public struct DesktopWorkflowV2PortfolioItem: Identifiable, Equatable, Sendable {
    public var id: String { workflowID }
    public let workflowID: String
    public let packageID: String
    public let name: String
    public let summary: String
    public let state: DesktopWorkflowV2PortfolioState
    public let hasDraft: Bool
    public let latestRevisionID: String?
    public let latestRevisionNumber: Int64?
    public let activeRevisionID: String?
    public let executionSupport: DesktopWorkflowV2ExecutionSupport?
}

public struct DesktopWorkflowV2RevisionSummary: Identifiable, Equatable, Sendable {
    public var id: String { revisionID }
    public let workflowID: String
    public let revisionID: String
    public let revisionNumber: Int64
    public let releaseVersion: String
    public let createdAtUnixMillis: Int64
    public let packageDigest: String
    public let isActive: Bool
    public let executionSupport: DesktopWorkflowV2ExecutionSupport
}

public struct DesktopWorkflowV2RevisionContent: Equatable, Sendable {
    public let summary: DesktopWorkflowV2RevisionSummary
    public let workflowJSON: Data
    public let layoutJSON: Data
    public let configurationJSON: Data
    public let compiledJSON: Data
}

public struct DesktopWorkflowV2RevisionComparison: Equatable, Sendable {
    public let workflowID: String
    public let fromRevisionID: String
    public let toRevisionID: String
    public let addedNodeIDs: [String]
    public let removedNodeIDs: [String]
    public let changedDefinitionPointers: [String]
    public let changedLayoutPointers: [String]
    public let changedConfigurationPointers: [String]
    public let truncated: Bool
}

public struct DesktopWorkflowV2Activation: Equatable, Sendable {
    public let workflowID: String
    public let aliasKey: String
    public let revisionID: String?
    public let generation: Int64
    public let duplicate: Bool
}

public struct DesktopWorkflowV2LibraryClient: Sendable {
    private let transport: any DesktopWorkflowLibraryTransport
    private let timeout: TimeInterval

    public init(
        transport: any DesktopWorkflowLibraryTransport,
        timeout: TimeInterval = 5
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func portfolio(
        aliasKey: String = "active",
        requestID: String
    ) async throws -> [DesktopWorkflowV2PortfolioItem] {
        var query = Kaname_V1_WorkflowPortfolioQuery()
        query.aliasKey = aliasKey
        var request = libraryRequest(requestID: requestID)
        request.query = .portfolio(query)
        let response = try await transport.queryWorkflowLibrary(request, timeout: timeout)
        try validate(response, requestID: requestID)
        return try response.portfolio.map(Self.portfolioItem)
    }

    public func revisionHistory(
        workflowID: String,
        aliasKey: String = "active",
        requestID: String
    ) async throws -> [DesktopWorkflowV2RevisionSummary] {
        var query = Kaname_V1_WorkflowRevisionHistoryQuery()
        query.workflowID = workflowID
        query.aliasKey = aliasKey
        var request = libraryRequest(requestID: requestID)
        request.query = .revisionHistory(query)
        let response = try await transport.queryWorkflowLibrary(request, timeout: timeout)
        try validate(response, requestID: requestID)
        return try response.revisionHistory.map(Self.revisionSummary)
    }

    public func revision(
        revisionID: String,
        aliasKey: String = "active",
        requestID: String
    ) async throws -> DesktopWorkflowV2RevisionContent {
        var query = Kaname_V1_WorkflowRevisionContentQuery()
        query.revisionID = revisionID
        query.aliasKey = aliasKey
        var request = libraryRequest(requestID: requestID)
        request.query = .revisionContent(query)
        let response = try await transport.queryWorkflowLibrary(request, timeout: timeout)
        try validate(response, requestID: requestID)
        guard response.hasRevisionContent else {
            throw DesktopWorkflowV2LibraryError.malformedResponse
        }
        let content = response.revisionContent
        guard content.hasSummary,
              !content.workflowJson.isEmpty,
              !content.layoutJson.isEmpty,
              !content.configurationJson.isEmpty,
              !content.compiledJson.isEmpty else {
            throw DesktopWorkflowV2LibraryError.malformedResponse
        }
        return DesktopWorkflowV2RevisionContent(
            summary: try Self.revisionSummary(content.summary),
            workflowJSON: content.workflowJson,
            layoutJSON: content.layoutJson,
            configurationJSON: content.configurationJson,
            compiledJSON: content.compiledJson
        )
    }

    public func compare(
        fromRevisionID: String,
        toRevisionID: String,
        requestID: String
    ) async throws -> DesktopWorkflowV2RevisionComparison {
        var query = Kaname_V1_WorkflowRevisionComparisonQuery()
        query.fromRevisionID = fromRevisionID
        query.toRevisionID = toRevisionID
        var request = libraryRequest(requestID: requestID)
        request.query = .revisionComparison(query)
        let response = try await transport.queryWorkflowLibrary(request, timeout: timeout)
        try validate(response, requestID: requestID)
        guard response.hasRevisionComparison else {
            throw DesktopWorkflowV2LibraryError.malformedResponse
        }
        let comparison = response.revisionComparison
        guard !comparison.workflowID.isEmpty,
              !comparison.fromRevisionID.isEmpty,
              !comparison.toRevisionID.isEmpty else {
            throw DesktopWorkflowV2LibraryError.malformedResponse
        }
        return DesktopWorkflowV2RevisionComparison(
            workflowID: comparison.workflowID,
            fromRevisionID: comparison.fromRevisionID,
            toRevisionID: comparison.toRevisionID,
            addedNodeIDs: comparison.addedNodeIds,
            removedNodeIDs: comparison.removedNodeIds,
            changedDefinitionPointers: comparison.changedDefinitionPointers,
            changedLayoutPointers: comparison.changedLayoutPointers,
            changedConfigurationPointers: comparison.changedConfigurationPointers,
            truncated: comparison.truncated
        )
    }

    public func setActivation(
        aliasID: String,
        workflowID: String,
        aliasKey: String = "active",
        revisionID: String?,
        expectedGeneration: Int64,
        updatedAtUnixMillis: Int64,
        requestID: String
    ) async throws -> DesktopWorkflowV2Activation {
        var request = Kaname_V1_SetWorkflowActivationRequest()
        request.schemaVersion = Self.schemaVersion
        request.requestID = requestID
        request.aliasID = aliasID
        request.workflowID = workflowID
        request.aliasKey = aliasKey
        request.revisionID = revisionID ?? ""
        request.expectedGeneration = expectedGeneration
        request.updatedAtUnixMillis = updatedAtUnixMillis
        let response = try await transport.setWorkflowActivation(request, timeout: timeout)
        guard response.schemaVersion.major == 1,
              response.requestID == requestID,
              response.workflowID == workflowID,
              response.aliasKey == aliasKey,
              response.generation >= 1 else {
            throw DesktopWorkflowV2LibraryError.malformedResponse
        }
        return DesktopWorkflowV2Activation(
            workflowID: response.workflowID,
            aliasKey: response.aliasKey,
            revisionID: response.revisionID.nilIfEmpty,
            generation: response.generation,
            duplicate: response.duplicate
        )
    }

    private func libraryRequest(requestID: String) -> Kaname_V1_WorkflowLibraryQueryRequest {
        var request = Kaname_V1_WorkflowLibraryQueryRequest()
        request.schemaVersion = Self.schemaVersion
        request.requestID = requestID
        return request
    }

    private func validate(
        _ response: Kaname_V1_WorkflowLibraryQueryResponse,
        requestID: String
    ) throws {
        guard response.schemaVersion.major == 1, response.requestID == requestID else {
            throw DesktopWorkflowV2LibraryError.malformedResponse
        }
    }

    private static var schemaVersion: Kaname_V1_SchemaVersion {
        var version = Kaname_V1_SchemaVersion()
        version.major = 1
        return version
    }

    private static func portfolioItem(
        _ item: Kaname_V1_WorkflowPortfolioItem
    ) throws -> DesktopWorkflowV2PortfolioItem {
        guard !item.workflowID.isEmpty,
              !item.packageID.isEmpty,
              !item.name.isEmpty,
              let state = DesktopWorkflowV2PortfolioState(item.state),
              item.latestRevisionNumber >= 0 else {
            throw DesktopWorkflowV2LibraryError.malformedResponse
        }
        return DesktopWorkflowV2PortfolioItem(
            workflowID: item.workflowID,
            packageID: item.packageID,
            name: item.name,
            summary: item.summary,
            state: state,
            hasDraft: item.draftPresent,
            latestRevisionID: item.latestRevisionID.nilIfEmpty,
            latestRevisionNumber: item.latestRevisionID.isEmpty ? nil : item.latestRevisionNumber,
            activeRevisionID: item.activeRevisionID.nilIfEmpty,
            executionSupport: DesktopWorkflowV2ExecutionSupport(item.executionSupport)
        )
    }

    private static func revisionSummary(
        _ summary: Kaname_V1_WorkflowRevisionSummary
    ) throws -> DesktopWorkflowV2RevisionSummary {
        guard !summary.workflowID.isEmpty,
              !summary.revisionID.isEmpty,
              summary.revisionNumber > 0,
              !summary.releaseVersion.isEmpty,
              summary.createdAtUnixMillis >= 0,
              summary.packageDigest.count == 64,
              let support = DesktopWorkflowV2ExecutionSupport(summary.executionSupport) else {
            throw DesktopWorkflowV2LibraryError.malformedResponse
        }
        return DesktopWorkflowV2RevisionSummary(
            workflowID: summary.workflowID,
            revisionID: summary.revisionID,
            revisionNumber: summary.revisionNumber,
            releaseVersion: summary.releaseVersion,
            createdAtUnixMillis: summary.createdAtUnixMillis,
            packageDigest: summary.packageDigest,
            isActive: summary.isActive,
            executionSupport: support
        )
    }
}

private extension DesktopWorkflowV2PortfolioState {
    init?(_ state: Kaname_V1_WorkflowPortfolioState) {
        switch state {
        case .draft: self = .draft
        case .published: self = .published
        case .active: self = .active
        case .disabled: self = .disabled
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }
}

private extension DesktopWorkflowV2ExecutionSupport {
    init?(_ support: Kaname_V1_WorkflowExecutionSupport) {
        switch support {
        case .executable: self = .executable
        case .unsupported: self = .unsupported
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
