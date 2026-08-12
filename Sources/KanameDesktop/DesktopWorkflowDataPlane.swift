import Foundation

public enum DesktopWorkflowDataScope: String, Codable, CaseIterable, Equatable, Sendable {
    case run
    case workItem
    case installation
    case accountBinding

    public var label: String {
        switch self {
        case .run: "This run"
        case .workItem: "This work item"
        case .installation: "This workflow"
        case .accountBinding: "This account binding"
        }
    }
}

struct DesktopWorkflowResolvedDataScope {
    let workflowID: String
    let workItemID: String
    let runID: String
    let accountIDs: Set<String>

    func identifier(for scope: DesktopWorkflowDataScope) -> String? {
        switch scope {
        case .run: runID
        case .workItem: workItemID
        case .installation: workflowID
        case .accountBinding: accountIDs.count == 1 ? accountIDs.first : nil
        }
    }
}

enum DesktopWorkflowCanonicalJSON {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

public struct DesktopWorkflowArtifactInputDefinition: Codable, Equatable, Sendable {
    public let role: String
    public let required: Bool

    public init(role: String, required: Bool = true) {
        self.role = role
        self.required = required
    }
}

public struct DesktopWorkflowStateInputDefinition: Codable, Equatable, Sendable {
    public let namespace: String
    public let key: String
    public let required: Bool
    public let scope: DesktopWorkflowDataScope?

    public init(
        namespace: String,
        key: String,
        required: Bool = false,
        scope: DesktopWorkflowDataScope = .installation
    ) {
        (self.namespace, self.key, self.required, self.scope) = (namespace, key, required, scope)
    }
}

public struct DesktopWorkflowStateRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(workflowID):\(scopeID ?? workflowID):\(namespace):\(key)" }
    public let workflowID: String
    public var namespace: String
    public var key: String
    public var scope: DesktopWorkflowDataScope
    public var scopeID: String?
    public var schemaVersion: Int
    public var schema: String
    public var value: Data
    public var revision: Int
    public var updatedByRunID: String
    public var updatedAtUnixMillis: Int64

    public init(
        workflowID: String,
        namespace: String,
        key: String,
        scope: DesktopWorkflowDataScope,
        scopeID: String,
        schemaVersion: Int,
        schema: String,
        value: Data,
        revision: Int,
        updatedByRunID: String,
        updatedAtUnixMillis: Int64
    ) {
        (self.workflowID, self.namespace, self.key, self.scope, self.scopeID) =
            (workflowID, namespace, key, scope, scopeID)
        (self.schemaVersion, self.schema, self.value, self.revision) = (schemaVersion, schema, value, revision)
        (self.updatedByRunID, self.updatedAtUnixMillis) = (updatedByRunID, updatedAtUnixMillis)
    }
}

extension DesktopWorkflowStateRecord {
    func matches(workflowID: String, scopeID: String, namespace: String, key: String) -> Bool {
        self.workflowID == workflowID && (self.scopeID ?? self.workflowID) == scopeID
            && self.namespace == namespace && self.key == key
    }
}

public struct DesktopWorkflowArtifactRoleRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var workItemID: String
    public var episodeID: String
    public var role: String
    public var artifactDigest: String
    public var filename: String
    public var mediaType: String
    public var active: Bool
    public var supersededByID: String?
    public var createdByRunID: String
    public var createdAtUnixMillis: Int64
}

public struct DesktopWorkflowCapabilityStateInput: Codable, Equatable, Sendable {
    public let namespace: String
    public let key: String
    public let schemaVersion: Int
    public let revision: Int
    public let value: Data

    private enum CodingKeys: String, CodingKey { case namespace, key, schemaVersion, revision, value }

    private struct DecodedPayload: Decodable {
        let namespace: String
        let key: String
        let schemaVersion: Int
        let revision: Int
        let value: DesktopWorkflowJSONValue
    }

    init(record: DesktopWorkflowStateRecord) {
        namespace = record.namespace
        key = record.key
        schemaVersion = record.schemaVersion
        revision = record.revision
        value = record.value
    }

    public init(from decoder: any Decoder) throws {
        let payload = try DecodedPayload(from: decoder)
        (namespace, key, schemaVersion, revision) =
            (payload.namespace, payload.key, payload.schemaVersion, payload.revision)
        value = try payload.value.canonicalData()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(namespace, forKey: .namespace)
        try container.encode(key, forKey: .key)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(DesktopWorkflowJSONValue.decode(value), forKey: .value)
    }
}

public struct DesktopWorkflowCapabilityArtifactInput: Codable, Equatable, Sendable {
    public let role: String
    public let artifactDigest: String
    public let filename: String
    public let mediaType: String
    public let data: Data
}

public struct DesktopWorkflowStateMutationProposal: Codable, Equatable, Sendable {
    public let namespace: String
    public let key: String
    public let scope: DesktopWorkflowDataScope
    public let expectedRevision: Int?
    public let schemaVersion: Int
    public let schema: String
    public let value: Data?

    private enum CodingKeys: String, CodingKey {
        case namespace, key, scope, expectedRevision, schemaVersion, schema, value, delete
    }

    private struct DecodedPayload: Decodable {
        let namespace: String
        let key: String
        let scope: DesktopWorkflowDataScope
        let expectedRevision: Int?
        let schemaVersion: Int
        let schema: String
        let value: DesktopWorkflowJSONValue?
        let delete: Bool?
    }

    public init(
        namespace: String,
        key: String,
        scope: DesktopWorkflowDataScope,
        expectedRevision: Int?,
        schemaVersion: Int,
        schema: String,
        value: Data?
    ) {
        (self.namespace, self.key, self.scope) = (namespace, key, scope)
        (self.expectedRevision, self.schemaVersion, self.schema, self.value) =
            (expectedRevision, schemaVersion, schema, value)
    }

    public init(from decoder: any Decoder) throws {
        let payload = try DecodedPayload(from: decoder)
        (namespace, key, scope) = (payload.namespace, payload.key, payload.scope)
        (expectedRevision, schemaVersion, schema) =
            (payload.expectedRevision, payload.schemaVersion, payload.schema)
        value = payload.delete == true ? nil : try payload.value?.canonicalData()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(namespace, forKey: .namespace)
        try container.encode(key, forKey: .key)
        try container.encode(scope, forKey: .scope)
        try container.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(schema, forKey: .schema)
        if let value {
            try container.encode(DesktopWorkflowJSONValue.decode(value), forKey: .value)
        } else {
            try container.encode(true, forKey: .delete)
        }
    }
}

public struct DesktopWorkflowKnowledgeProposal: Codable, Equatable, Sendable {
    public let key: String
    public let value: String
    public let scope: DesktopWorkflowDataScope
    public let sourceReferenceIDs: [String]
    public let supersedesFactID: String?
}

public struct DesktopWorkflowArtifactRoleProposal: Codable, Equatable, Sendable {
    public let role: String
    public let artifactDigest: String
}

public struct DesktopWorkflowCapabilityCommitProposal: Codable, Equatable, Sendable {
    public var stateMutations: [DesktopWorkflowStateMutationProposal]
    public var knowledgeProposals: [DesktopWorkflowKnowledgeProposal]
    public var artifactRoles: [DesktopWorkflowArtifactRoleProposal]

    public init(
        stateMutations: [DesktopWorkflowStateMutationProposal] = [],
        knowledgeProposals: [DesktopWorkflowKnowledgeProposal] = [],
        artifactRoles: [DesktopWorkflowArtifactRoleProposal] = []
    ) {
        self.stateMutations = stateMutations
        self.knowledgeProposals = knowledgeProposals
        self.artifactRoles = artifactRoles
    }

    public var isEmpty: Bool {
        stateMutations.isEmpty && knowledgeProposals.isEmpty && artifactRoles.isEmpty
    }
}

public enum DesktopWorkflowDataPlaneError: Error, Equatable, LocalizedError, Sendable {
    case invalidDeclaration
    case requiredInputMissing
    case invalidCommitProposal
    case stateConflict

    public var errorDescription: String? {
        switch self {
        case .invalidDeclaration: "The workflow step declares an invalid artifact or state input."
        case .requiredInputMissing: "A required workflow artifact or state value is unavailable."
        case .invalidCommitProposal: "The capability proposed invalid or unauthorized workflow data changes."
        case .stateConflict: "Workflow state changed after this capability began; review and rerun the step."
        }
    }
}

enum DesktopWorkflowDataPlaneValidation {
    static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }

    static func validate(_ proposal: DesktopWorkflowCapabilityCommitProposal) throws {
        guard proposal.stateMutations.count <= 64,
              proposal.knowledgeProposals.count <= 64,
              proposal.artifactRoles.count <= 64,
              proposal.stateMutations.allSatisfy({ mutation in
                  validIdentifier(mutation.namespace) && validIdentifier(mutation.key)
                      && mutation.schemaVersion > 0 && mutation.schema.utf8.count <= 64 * 1_024
                      && (mutation.expectedRevision.map({ $0 >= 0 }) ?? true)
                      && DesktopWorkflowJSONSchemaValidator.validateSchema(Data(mutation.schema.utf8))
                      && mutation.value.map({ value in
                          value.count <= DesktopWorkflowStorage.maximumValueBytes
                              && DesktopWorkflowJSONSchemaValidator.validates(instance: value, against: mutation.schema)
                      }) ?? true
              }),
              proposal.knowledgeProposals.allSatisfy({ fact in
                  !fact.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && fact.key.utf8.count <= 240 && !fact.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && fact.value.utf8.count <= 8_192 && fact.sourceReferenceIDs.count <= 64
              }),
              proposal.artifactRoles.allSatisfy({
                  validIdentifier($0.role)
                      && $0.artifactDigest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
              }) else { throw DesktopWorkflowDataPlaneError.invalidCommitProposal }
    }
}

private indirect enum DesktopWorkflowJSONValue: Codable, Equatable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Self].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .boolean(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    func canonicalData() throws -> Data {
        try DesktopWorkflowCanonicalJSON.encode(self)
    }
}

public enum DesktopWorkflowModelContextCompiler {
    public static func augment(
        prompt: String,
        context: DesktopWorkflowContextSnapshotRecord?,
        maximumBytes: Int = 100_000
    ) -> String? {
        guard let context else { return prompt.utf8.count <= maximumBytes ? prompt : nil }
        let verified = (context.knowledge ?? []).map {
            "- \($0.key): \($0.value) [\($0.scope.rawValue); sources: \($0.sourceReferenceIDs.joined(separator: ", "))]"
        }.joined(separator: "\n")
        let exclusions = context.negativeConstraints.map { "- \($0)" }.joined(separator: "\n")
        let questions = context.openQuestions.map { "- \($0)" }.joined(separator: "\n")
        let references = context.references.filter(\.included).map {
            "- \($0.kind): \($0.label) [digest: \($0.digest); reason: \($0.reason)]"
        }.joined(separator: "\n")
        let compiled = """
        \(prompt)

        KANAME FROZEN WORKFLOW CONTEXT
        Current request:
        \(context.currentRequest)

        Verified knowledge:
        \(verified.isEmpty ? "- None" : verified)

        Explicit exclusions:
        \(exclusions.isEmpty ? "- None" : exclusions)

        Open questions:
        \(questions.isEmpty ? "- None" : questions)

        Included provenance references:
        \(references.isEmpty ? "- None" : references)

        Authority: \(context.authoritySummary)
        Declared egress: \(context.dataEgressSummary)
        Context digest: \(context.digest)
        """
        return compiled.utf8.count <= maximumBytes ? compiled : nil
    }
}

public extension DesktopAppModel {
    func workflowStateRecords(workflowID: String) -> [DesktopWorkflowStateRecord] {
        snapshot.operations.workflows.stateRecords.filter { $0.workflowID == workflowID }
            .sorted { ($0.namespace, $0.key) < ($1.namespace, $1.key) }
    }

    func workflowArtifactRoles(workItemID: String, includeInactive: Bool = false) -> [DesktopWorkflowArtifactRoleRecord] {
        snapshot.operations.workflows.artifactRoles.filter {
            $0.workItemID == workItemID && (includeInactive || $0.active)
        }.sorted { ($0.role, $0.createdAtUnixMillis, $0.id) < ($1.role, $1.createdAtUnixMillis, $1.id) }
    }

    func workflowKnowledge(workflowID: String, includeInactive: Bool = false) -> [DesktopWorkflowFactRecord] {
        snapshot.operations.workflows.facts.filter {
            $0.workflowID == workflowID && (includeInactive || $0.state == .proposed || $0.state == .verified)
        }.sorted { ($0.key, $0.createdAtUnixMillis, $0.id) < ($1.key, $1.createdAtUnixMillis, $1.id) }
    }

    @discardableResult
    func reviewWorkflowKnowledge(id: String, accepted: Bool, reviewer: String) -> Bool {
        let cleanReviewer = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanReviewer.isEmpty, cleanReviewer.utf8.count <= 240,
              snapshot.operations.workflows.facts.contains(where: { $0.id == id && $0.state == .proposed }) else {
            return false
        }
        return mutate { state in
            guard let index = state.operations.workflows.facts.firstIndex(where: { $0.id == id && $0.state == .proposed }) else {
                return
            }
            state.operations.workflows.facts[index].state = accepted ? .verified : .rejected
            state.operations.workflows.facts[index].verifiedBy = cleanReviewer
            if accepted,
               let priorID = state.operations.workflows.facts[index].proposedSupersedesFactID,
               let priorIndex = state.operations.workflows.facts.firstIndex(where: { $0.id == priorID && $0.state == .verified }) {
                state.operations.workflows.facts[priorIndex].state = .superseded
                state.operations.workflows.facts[priorIndex].supersededByFactID = id
            }
            state.appendAudit(
                domain: "workflow-knowledge", action: accepted ? "verified" : "rejected", target: id,
                state: .completed, detail: "Reviewed by \(cleanReviewer).", recordedAtUnixMillis: now()
            )
        }
    }

    @discardableResult
    func bindWorkflowArtifactRole(
        workflowID: String,
        workItemID: String,
        episodeID: String,
        role: String,
        artifact: DesktopWorkflowStoredArtifact,
        createdByRunID: String
    ) -> String? {
        guard DesktopWorkflowDataPlaneValidation.validIdentifier(role),
              snapshot.operations.workflows.workItems.contains(where: { $0.id == workItemID && $0.workflowID == workflowID }),
              snapshot.operations.workflows.episodes.contains(where: { $0.id == episodeID && $0.workItemID == workItemID }) else {
            return nil
        }
        let timestamp = now()
        let record = DesktopWorkflowArtifactRoleRecord(
            id: UUID().uuidString.lowercased(), workflowID: workflowID, workItemID: workItemID,
            episodeID: episodeID, role: role, artifactDigest: artifact.sha256, filename: artifact.filename,
            mediaType: artifact.mediaType, active: true, supersededByID: nil,
            createdByRunID: createdByRunID, createdAtUnixMillis: timestamp
        )
        guard mutate({ state in
            for index in state.operations.workflows.artifactRoles.indices
                where state.operations.workflows.artifactRoles[index].workflowID == workflowID
                    && state.operations.workflows.artifactRoles[index].workItemID == workItemID
                    && state.operations.workflows.artifactRoles[index].role == role
                    && state.operations.workflows.artifactRoles[index].active {
                state.operations.workflows.artifactRoles[index].active = false
                state.operations.workflows.artifactRoles[index].supersededByID = record.id
            }
            state.operations.workflows.artifactRoles.append(record)
            state.appendAudit(
                domain: "workflow-artifact", action: "role-published", target: record.id,
                state: .completed, detail: "\(role) · \(artifact.sha256.prefix(12))",
                recordedAtUnixMillis: timestamp
            )
        }) else { return nil }
        return record.id
    }
}
