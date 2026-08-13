import CryptoKit
import Foundation

// MARK: - Declarative graph contracts

public enum DesktopWorkflowPredicateOperator: String, Codable, CaseIterable, Equatable, Sendable {
    case exists
    case equals
    case notEquals
    case contains
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
}

public struct DesktopWorkflowPredicate: Codable, Equatable, Sendable {
    public var pointer: String
    public var operation: DesktopWorkflowPredicateOperator
    public var value: String?

    public init(pointer: String, operation: DesktopWorkflowPredicateOperator, value: String? = nil) {
        self.pointer = pointer
        self.operation = operation
        self.value = value
    }
}

public enum DesktopWorkflowTransitionOutcome: String, Codable, CaseIterable, Equatable, Sendable {
    case always
    case matched
    case notMatched
    case approved
    case rejected
    case edited
    case selected
    case acknowledged
    case succeeded
    case failed
    case timedOut
    case cancelled
}

public struct DesktopWorkflowTransitionDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(outcome.rawValue):\(targetStepID)" }
    public var outcome: DesktopWorkflowTransitionOutcome
    public var targetStepID: String
    public var predicates: [DesktopWorkflowPredicate]

    public init(
        outcome: DesktopWorkflowTransitionOutcome,
        targetStepID: String,
        predicates: [DesktopWorkflowPredicate] = []
    ) {
        self.outcome = outcome
        self.targetStepID = targetStepID
        self.predicates = predicates
    }
}

public struct DesktopWorkflowExecutionPolicy: Codable, Equatable, Sendable {
    public var timeoutSeconds: Int
    public var maximumAttempts: Int
    public var maximumOutputBytes: Int
    public var maximumItems: Int

    public init(
        timeoutSeconds: Int = 120,
        maximumAttempts: Int = 1,
        maximumOutputBytes: Int = 8 * 1_024 * 1_024,
        maximumItems: Int = 1_000
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.maximumAttempts = maximumAttempts
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumItems = maximumItems
    }
}

public struct DesktopWorkflowTransitionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var runID: String
    public var fromStepID: String
    public var toStepID: String?
    public var outcome: DesktopWorkflowTransitionOutcome
    public var decisionDigest: String
    public var createdAtUnixMillis: Int64
}

// MARK: - Structured human decisions

public enum DesktopWorkflowReviewActionKind: String, Codable, CaseIterable, Equatable, Sendable {
    case approve
    case reject
    case edit
    case select
    case acknowledge
    case escalate

    public var label: String { rawValue.capitalized }
}

public struct DesktopWorkflowReviewActionDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var kind: DesktopWorkflowReviewActionKind
    public var isPrimary: Bool

    public init(id: String, label: String, kind: DesktopWorkflowReviewActionKind, isPrimary: Bool = false) {
        (self.id, self.label, self.kind, self.isPrimary) = (id, label, kind, isPrimary)
    }
}

public struct DesktopWorkflowReviewContract: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var inputSchema: String
    public var outputSchema: String
    public var presentationHints: [String: String] = [:]
    public var actions: [DesktopWorkflowReviewActionDefinition]
    public var invalidateValidationOnEdit: Bool = true

    public init(
        title: String,
        summary: String,
        inputSchema: String,
        outputSchema: String,
        presentationHints: [String: String] = [:],
        actions: [DesktopWorkflowReviewActionDefinition],
        invalidateValidationOnEdit: Bool = true
    ) {
        self.title = title
        self.summary = summary
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.presentationHints = presentationHints
        self.actions = actions
        self.invalidateValidationOnEdit = invalidateValidationOnEdit
    }

}

public enum DesktopWorkflowReviewState: String, Codable, CaseIterable, Equatable, Sendable {
    case pending
    case resolved
    case cancelled
}

public struct DesktopWorkflowReviewRequestRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var workItemID: String
    public var episodeID: String
    public var runID: String
    public var stepID: String
    public var contract: DesktopWorkflowReviewContract
    public var proposedValue: Data
    public var proposedValueDigest: String
    public var state: DesktopWorkflowReviewState
    public var selectedActionID: String?
    public var resolvedValue: Data?
    public var resolvedValueDigest: String?
    public var reviewer: String?
    public var createdAtUnixMillis: Int64
    public var resolvedAtUnixMillis: Int64?
}

// MARK: - Resumable external waits

public struct DesktopWorkflowWaitContract: Codable, Equatable, Sendable {
    public var connectorID: String
    public var source: String
    public var accountPointer: String? = nil
    public var conversationPointer: String? = nil
    public var correlationPointer: String? = nil
    public var timeoutSeconds: Int = 604_800
    public var supersedePrior: Bool = true

    public init(
        connectorID: String,
        source: String,
        accountPointer: String? = nil,
        conversationPointer: String? = nil,
        correlationPointer: String? = nil,
        timeoutSeconds: Int = 604_800,
        supersedePrior: Bool = true
    ) {
        self.connectorID = connectorID
        self.source = source
        self.accountPointer = accountPointer
        self.conversationPointer = conversationPointer
        self.correlationPointer = correlationPointer
        self.timeoutSeconds = timeoutSeconds
        self.supersedePrior = supersedePrior
    }

}

public enum DesktopWorkflowWaitState: String, Codable, CaseIterable, Equatable, Sendable {
    case active
    case resolved
    case timedOut
    case superseded
    case cancelled
}

public struct DesktopWorkflowWaitSubscriptionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var workItemID: String
    public var episodeID: String
    public var runID: String
    public var stepID: String
    public var connectorID: String
    public var source: String
    public var accountID: String?
    public var conversationID: String?
    public var correlationPointer: String?
    public var correlationValue: String?
    public var state: DesktopWorkflowWaitState
    public var createdAtUnixMillis: Int64
    public var deadlineUnixMillis: Int64
    public var resolvedEventID: String?
    public var resolvedAtUnixMillis: Int64?
}

// MARK: - Workflow-owned datasets

public enum DesktopWorkflowDatasetScope: String, Codable, CaseIterable, Equatable, Sendable {
    case installation
    case accountBinding
    case workItem
}

public struct DesktopWorkflowDatasetDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var scope: DesktopWorkflowDatasetScope = .installation
    public var rowSchema: String
    public var uniqueKeyPointers: [String]
    public var indexPointers: [String] = []
    public var maximumRows: Int = 100_000

}

public struct DesktopWorkflowDatasetRowRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var datasetID: String
    public var scopeID: String
    public var uniqueKey: String
    public var value: Data
    public var valueDigest: String
    public var revision: Int
    public var updatedByRunID: String
    public var updatedAtUnixMillis: Int64
}

public struct DesktopWorkflowDatasetMutation: Codable, Equatable, Sendable {
    public var datasetID: String
    public var scopeID: String
    public var expectedRevision: Int?
    public var rows: [Data]

    public static func request(
        datasetID: String,
        scopeID: String,
        expectedRevision: Int? = nil,
        rows: [Data]
    ) -> Self {
        Self(datasetID: datasetID, scopeID: scopeID, expectedRevision: expectedRevision, rows: rows)
    }
}

// MARK: - Validation and execution evidence

public struct DesktopWorkflowValidationFinding: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var severity: DesktopWorkflowValidationSeverity
    public var location: String?
    public var summary: String
    public var evidence: String

    public static func report(
        id: String,
        severity: DesktopWorkflowValidationSeverity,
        location: String? = nil,
        summary: String,
        evidence: String
    ) -> Self {
        Self(id: id, severity: severity, location: location, summary: summary, evidence: evidence)
    }

}

public struct DesktopWorkflowValidatorReportRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var validationID: String
    public var validatorID: String
    public var validatorVersion: String
    public var subjectDigest: String
    public var findings: [DesktopWorkflowValidationFinding]
    public var createdAtUnixMillis: Int64
}

public struct DesktopWorkflowCapabilityExecutionEvidence: Codable, Equatable, Sendable {
    public var standardOutput: String
    public var standardError: String
    public var elapsedMilliseconds: Int64

    public init(standardOutput: String = "", standardError: String = "", elapsedMilliseconds: Int64 = 0) {
        self.standardOutput = DesktopWorkflowEvidenceRedactor.redact(standardOutput)
        self.standardError = DesktopWorkflowEvidenceRedactor.redact(standardError)
        self.elapsedMilliseconds = max(0, elapsedMilliseconds)
    }
}

public enum DesktopWorkflowEvidenceRedactor {
    private static let patterns: [(String, String)] = [
        (#"(?i)\b(authorization\s*:\s*(?:bearer|basic)\s+)[^\s]+"#, "$1[redacted]"),
        (#"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password)\s*[:=]\s*[^\s,;]+"#, "$1=[redacted]"),
        (#"\b[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b"#, "[redacted-token]"),
        (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[redacted-email]"),
        (#"/Users/[^/\s]+"#, "/Users/[redacted]"),
    ]

    public static func redact(_ value: String) -> String {
        var result = String(value.prefix(32_768))
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }
}

public struct DesktopWorkflowExecutionReceiptRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var runID: String
    public var stepAttemptID: String
    public var capabilityID: String
    public var inputDigest: String
    public var outputDigest: String?
    public var artifactDigests: [String]
    public var standardOutput: String
    public var standardError: String
    public var elapsedMilliseconds: Int64
    public var createdAtUnixMillis: Int64
}

// MARK: - Connector effects and scoped authority

public enum DesktopWorkflowAuthorityGrantState: String, Codable, CaseIterable, Equatable, Sendable {
    case active
    case paused
    case revoked
    case expired
}

public struct DesktopWorkflowAuthorityGrantRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var connectorID: String
    public var effectKind: String
    public var accountIDs: [String]
    public var targetPredicates: [DesktopWorkflowPredicate]
    public var requiresManualRun: Bool
    public var maximumItemsPerExecution: Int
    public var postcondition: String
    public var state: DesktopWorkflowAuthorityGrantState
    public var createdAtUnixMillis: Int64
    public var expiresAtUnixMillis: Int64?
    public var lastUsedAtUnixMillis: Int64?
    public var useCount: Int
    public var maximumUses: Int? = nil
    public var sourcePreviewID: String? = nil
    public var sourceTargetDigest: String? = nil
}

public struct DesktopWorkflowEffectRequest: Codable, Equatable, Sendable {
    public var workflowID: String
    public var workItemID: String
    public var episodeID: String
    public var runID: String
    public var stepID: String
    public var connectorID: String
    public var effectKind: String
    public var accountID: String?
    public var target: Data
    public var payload: Data
    public var artifactDigests: [String]
    public var itemCount: Int
    public var manuallyInitiated: Bool

    public init(
        workflowID: String,
        workItemID: String,
        episodeID: String,
        runID: String,
        stepID: String,
        connectorID: String,
        effectKind: String,
        accountID: String?,
        target: Data,
        payload: Data,
        artifactDigests: [String],
        itemCount: Int,
        manuallyInitiated: Bool
    ) {
        self.workflowID = workflowID
        self.workItemID = workItemID
        self.episodeID = episodeID
        self.runID = runID
        self.stepID = stepID
        self.connectorID = connectorID
        self.effectKind = effectKind
        self.accountID = accountID
        self.target = target
        self.payload = payload
        self.artifactDigests = artifactDigests
        self.itemCount = itemCount
        self.manuallyInitiated = manuallyInitiated
    }
}

public struct DesktopWorkflowEffectPreview: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var exactTarget: String
    public var structuredTarget: Data
    public var itemCount: Int
    public var consequences: [String]
    public var reversible: Bool

    public init(
        title: String,
        summary: String,
        exactTarget: String,
        structuredTarget: Data,
        itemCount: Int,
        consequences: [String],
        reversible: Bool
    ) {
        self.title = String(title.prefix(512))
        self.summary = String(summary.prefix(8_192))
        self.exactTarget = String(exactTarget.prefix(8_192))
        self.structuredTarget = Data(structuredTarget.prefix(1 * 1_024 * 1_024))
        self.itemCount = max(0, itemCount)
        self.consequences = consequences.prefix(64).map { String($0.prefix(2_048)) }
        self.reversible = reversible
    }
}

public struct DesktopWorkflowEffectPreviewRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var effectID: String
    public var request: DesktopWorkflowEffectRequest
    public var connectorID: String
    public var title: String
    public var summary: String
    public var structuredTarget: Data
    public var structuredTargetDigest: String
    public var itemCount: Int
    public var consequences: [String]
    public var reversible: Bool
    public var authorityGrantID: String?
    public var createdAtUnixMillis: Int64
}

public struct DesktopWorkflowConnectorExecutionReceipt: Codable, Equatable, Sendable {
    public var remoteReceipt: String?
    public var outcomeKnown: Bool
    public var succeeded: Bool
    public var detail: String

    public static func result(
        remoteReceipt: String? = nil,
        outcomeKnown: Bool,
        succeeded: Bool,
        detail: String
    ) -> Self {
        Self(remoteReceipt: remoteReceipt, outcomeKnown: outcomeKnown, succeeded: succeeded, detail: detail)
    }
}

public protocol DesktopWorkflowConnector: Sendable {
    var identifier: String { get }
    func preview(_ request: DesktopWorkflowEffectRequest) async throws -> DesktopWorkflowEffectPreview
    func execute(
        _ request: DesktopWorkflowEffectRequest,
        preview: DesktopWorkflowEffectPreview,
        idempotencyKey: String
    ) async throws -> DesktopWorkflowConnectorExecutionReceipt
    func reconcile(
        _ request: DesktopWorkflowEffectRequest,
        preview: DesktopWorkflowEffectPreview,
        idempotencyKey: String,
        priorReceipt: DesktopWorkflowConnectorExecutionReceipt?
    ) async throws -> DesktopWorkflowConnectorExecutionReceipt
}

// MARK: - Bounded agent and extension contracts

public struct DesktopWorkflowAgentPolicy: Codable, Equatable, Sendable {
    public var allowedCapabilityIDs: [String]
    public var maximumModelTokens: Int
    public var maximumToolCalls: Int
    public var timeoutSeconds: Int
    public var allowDirectEffects: Bool

    public init(
        allowedCapabilityIDs: [String],
        maximumModelTokens: Int = 32_000,
        maximumToolCalls: Int = 16,
        timeoutSeconds: Int = 600,
        allowDirectEffects: Bool = false
    ) {
        self.allowedCapabilityIDs = Array(Set(allowedCapabilityIDs)).sorted()
        self.maximumModelTokens = maximumModelTokens
        self.maximumToolCalls = maximumToolCalls
        self.timeoutSeconds = timeoutSeconds
        self.allowDirectEffects = allowDirectEffects
    }
}

public enum DesktopWorkflowExtensionComponentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case workflow
    case capability
    case validator
    case renderer
    case connector
    case schema
    case fixture
}

public struct DesktopWorkflowExtensionComponent: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var kind: DesktopWorkflowExtensionComponentKind
    public var path: String
    public var sha256: String
}

public struct DesktopWorkflowExtensionManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var source: String
    public var license: String
    public var components: [DesktopWorkflowExtensionComponent]
}

public enum DesktopWorkflowHostFrameworkError: Error, Equatable, LocalizedError, Sendable {
    case invalidContract(String)
    case invalidJSONPointer
    case predicateFailed
    case reviewUnavailable
    case reviewValueInvalid
    case waitUnavailable
    case datasetUnavailable
    case datasetConflict
    case datasetLimitExceeded
    case authorityUnavailable
    case effectUnavailable
    case connectorUnavailable

    public var errorDescription: String? {
        switch self {
        case let .invalidContract(detail): "The workflow host contract is invalid: \(detail)"
        case .invalidJSONPointer: "The workflow uses an invalid or unsupported JSON Pointer."
        case .predicateFailed: "No declared workflow transition matched the structured value."
        case .reviewUnavailable: "The requested workflow review is no longer pending."
        case .reviewValueInvalid: "The reviewed value does not satisfy the declared output schema."
        case .waitUnavailable: "The workflow wait is no longer active or does not match this event."
        case .datasetUnavailable: "The declared workflow dataset is unavailable in this revision."
        case .datasetConflict: "The workflow dataset changed since this mutation was prepared."
        case .datasetLimitExceeded: "The workflow dataset exceeds its reviewed row or byte limit."
        case .authorityUnavailable: "No active authority grant covers this exact workflow effect."
        case .effectUnavailable: "The workflow effect is not ready for this operation."
        case .connectorUnavailable: "The required workflow connector is unavailable."
        }
    }
}

public enum DesktopWorkflowStructuredValue {
    public static func value(at pointer: String, in data: Data) throws -> Any? {
        guard pointer.isEmpty || pointer.hasPrefix("/") else {
            throw DesktopWorkflowHostFrameworkError.invalidJSONPointer
        }
        let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard !pointer.isEmpty else { return root }
        return pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst().reduce(root as Any?) { value, token in
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = value as? [String: Any] { return object[key] }
            if let array = value as? [Any], let index = Int(key), array.indices.contains(index) { return array[index] }
            return nil
        }
    }

    public static func string(at pointer: String, in data: Data) throws -> String? {
        guard let value = try value(at: pointer, in: data) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if value is NSNull { return nil }
        let encoded = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(data: encoded, encoding: .utf8)
    }

    public static func matches(_ predicates: [DesktopWorkflowPredicate], data: Data) -> Bool {
        predicates.allSatisfy { predicate in
            guard let actual = try? value(at: predicate.pointer, in: data) else { return false }
            switch predicate.operation {
            case .exists:
                return !(actual is NSNull)
            case .equals, .notEquals:
                let matched = scalarString(actual) == predicate.value
                return predicate.operation == .equals ? matched : !matched
            case .contains:
                if let string = actual as? String { return predicate.value.map(string.contains) == true }
                if let values = actual as? [Any] { return values.contains { scalarString($0) == predicate.value } }
                return false
            case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
                guard let left = scalarString(actual).flatMap(Double.init), let right = predicate.value.flatMap(Double.init) else {
                    return false
                }
                switch predicate.operation {
                case .lessThan: return left < right
                case .lessThanOrEqual: return left <= right
                case .greaterThan: return left > right
                case .greaterThanOrEqual: return left >= right
                default: return false
                }
            }
        }
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func scalarString(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        if value is NSNull || value == nil { return nil }
        return nil
    }
}

public enum DesktopWorkflowGraphResolver {
    public static func transition(
        from step: DesktopWorkflowStepDefinition,
        outcome: DesktopWorkflowTransitionOutcome,
        value: Data
    ) -> DesktopWorkflowTransitionDefinition? {
        let transitions = step.transitions ?? []
        if let exact = transitions.first(where: {
            $0.outcome == outcome && DesktopWorkflowStructuredValue.matches($0.predicates, data: value)
        }) {
            return exact
        }
        return transitions.first(where: {
            $0.outcome == .always && DesktopWorkflowStructuredValue.matches($0.predicates, data: value)
        })
    }
}

public enum DesktopWorkflowHostContractValidation {
    public static func validateGraph(_ steps: [DesktopWorkflowStepDefinition]) throws {
        guard let entry = steps.first, steps.last?.kind == .complete else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("a v2 graph needs an entry and terminal node")
        }
        let byID = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })
        var visiting = Set<String>()
        var visited = Set<String>()
        func visit(_ id: String) throws {
            guard let step = byID[id], !visiting.contains(id) else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("workflow graphs cannot contain unbounded cycles")
            }
            guard !visited.contains(id) else { return }
            visiting.insert(id)
            if step.kind == .complete {
                guard (step.transitions ?? []).isEmpty else {
                    throw DesktopWorkflowHostFrameworkError.invalidContract("terminal nodes cannot transition")
                }
            } else {
                guard let transitions = step.transitions, !transitions.isEmpty else {
                    throw DesktopWorkflowHostFrameworkError.invalidContract("every non-terminal node needs an edge")
                }
                for transition in transitions { try visit(transition.targetStepID) }
            }
            visiting.remove(id)
            visited.insert(id)
        }
        try visit(entry.id)
        guard visited == Set(byID.keys) else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("every graph node must be reachable from the entry")
        }
    }

    public static func validate(step: DesktopWorkflowStepDefinition, stepIDs: Set<String>) throws {
        if let transitions = step.transitions {
            guard !transitions.isEmpty, transitions.count <= 32,
                  transitions.allSatisfy({ stepIDs.contains($0.targetStepID) && $0.predicates.count <= 32 }),
                  Set(transitions.map(\.id)).count == transitions.count else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("step \(step.id) has invalid transitions")
            }
            for transition in transitions {
                for predicate in transition.predicates {
                    guard predicate.pointer.isEmpty || predicate.pointer.hasPrefix("/") else {
                        throw DesktopWorkflowHostFrameworkError.invalidJSONPointer
                    }
                }
            }
        }
        if let review = step.reviewContract {
            guard !review.title.isEmpty, !review.summary.isEmpty,
                  DesktopWorkflowJSONSchemaValidator.validateSchema(Data(review.inputSchema.utf8)),
                  DesktopWorkflowJSONSchemaValidator.validateSchema(Data(review.outputSchema.utf8)),
                  !review.actions.isEmpty, review.actions.count <= 8,
                  Set(review.actions.map(\.id)).count == review.actions.count else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("step \(step.id) has an invalid review contract")
            }
        }
        if let wait = step.waitContract {
            guard !wait.connectorID.isEmpty, !wait.source.isEmpty, (60...31_536_000).contains(wait.timeoutSeconds) else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("step \(step.id) has an invalid wait contract")
            }
        }
        if let policy = step.executionPolicy {
            guard (1...3_600).contains(policy.timeoutSeconds), (1...6).contains(policy.maximumAttempts),
                  (1...64 * 1_024 * 1_024).contains(policy.maximumOutputBytes),
                  (1...100_000).contains(policy.maximumItems),
                  step.retryLimit + 1 <= policy.maximumAttempts else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("step \(step.id) has invalid execution limits")
            }
        }
        if let agent = step.agentPolicy {
            guard step.kind == .agent, !agent.allowDirectEffects, !agent.allowedCapabilityIDs.isEmpty,
                  (256...200_000).contains(agent.maximumModelTokens),
                  (1...128).contains(agent.maximumToolCalls),
                  (1...3_600).contains(agent.timeoutSeconds) else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("step \(step.id) has an unsafe agent policy")
            }
        } else if step.kind == .agent {
            throw DesktopWorkflowHostFrameworkError.invalidContract("agent step \(step.id) needs a bounded agent policy")
        }
        if let batch = step.batchPolicy {
            guard step.kind == .forEach, batch.itemsPointer.hasPrefix("/"),
                  (1...10_000).contains(batch.maximumItems),
                  (1...32).contains(batch.maximumConcurrency) else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("step \(step.id) has an invalid batch policy")
            }
        } else if step.kind == .forEach {
            throw DesktopWorkflowHostFrameworkError.invalidContract("batch step \(step.id) needs bounded item and aggregation policy")
        }
        let mappings = step.inputMappings ?? []
        guard mappings.count <= 128, Set(mappings.map(\.id)).count == mappings.count,
              Set(mappings.map(\.targetPointer)).count == mappings.count else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("step \(step.id) has duplicate or excessive input mappings")
        }
    }

    public static func validate(dataset: DesktopWorkflowDatasetDefinition) throws {
        guard dataset.id.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil,
              !dataset.name.isEmpty, DesktopWorkflowJSONSchemaValidator.validateSchema(Data(dataset.rowSchema.utf8)),
              !dataset.uniqueKeyPointers.isEmpty, dataset.uniqueKeyPointers.count <= 8,
              dataset.indexPointers.count <= 16, (1...1_000_000).contains(dataset.maximumRows),
              (dataset.uniqueKeyPointers + dataset.indexPointers).allSatisfy({ $0.hasPrefix("/") }) else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("dataset \(dataset.id) is invalid")
        }
    }
}

public enum DesktopWorkflowExtensionCodec {
    public static let maximumManifestBytes = 256 * 1_024

    public static func decode(_ data: Data) throws -> DesktopWorkflowExtensionManifest {
        guard !data.isEmpty, data.count <= maximumManifestBytes,
              let manifest = try? JSONDecoder().decode(DesktopWorkflowExtensionManifest.self, from: data) else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("extension manifest is unreadable")
        }
        try validate(manifest)
        return manifest
    }

    public static func validate(_ manifest: DesktopWorkflowExtensionManifest) throws {
        let identifier = #"^[a-z0-9][a-z0-9._-]{0,127}$"#
        let digest = #"^[0-9a-f]{64}$"#
        guard manifest.schemaVersion == 1,
              manifest.id.range(of: identifier, options: .regularExpression) != nil,
              !manifest.name.isEmpty,
              manifest.version.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil,
              !manifest.source.isEmpty, !manifest.license.isEmpty,
              !manifest.components.isEmpty, manifest.components.count <= 1_000,
              Set(manifest.components.map(\.path)).count == manifest.components.count,
              manifest.components.allSatisfy({ component in
                  DesktopWorkflowCapabilityPackageCodec.safeRelativePath(component.path)
                      && component.sha256.range(of: digest, options: .regularExpression) != nil
              }) else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("extension manifest fields are invalid")
        }
    }
}

public struct DesktopWorkflowExtensionInspection: Equatable, Sendable {
    public var manifest: DesktopWorkflowExtensionManifest
    public var packageDigest: String
    public var totalBytes: Int
}

public struct DesktopWorkflowExtensionStore: Sendable {
    public static let manifestFilename = "extension.json"
    public let maximumPackageBytes: Int

    public init(maximumPackageBytes: Int = 512 * 1_024 * 1_024) {
        self.maximumPackageBytes = maximumPackageBytes
    }

    public func inspectPackage(at packageURL: URL) throws -> DesktopWorkflowExtensionInspection {
        let root = packageURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("extension package is not a directory")
        }
        let manifestURL = root.appendingPathComponent(Self.manifestFilename).standardizedFileURL
        let manifestData = try DesktopWorkflowFilesystem.requiredBoundedRegularData(
            at: manifestURL,
            maximumBytes: DesktopWorkflowExtensionCodec.maximumManifestBytes,
            mapped: true,
            failure: DesktopWorkflowHostFrameworkError.invalidContract("extension manifest is unavailable")
        )
        let manifest = try DesktopWorkflowExtensionCodec.decode(manifestData)
        let declared = Set(manifest.components.map(\.path)).union([Self.manifestFilename])
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("extension package cannot be enumerated")
        }
        var discovered = Set<String>()
        var total = manifestData.count
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("extension packages cannot contain symbolic links")
            }
            guard values.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard DesktopWorkflowCapabilityPackageCodec.safeRelativePath(relative), declared.contains(relative) else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("extension contains an undeclared file")
            }
            discovered.insert(relative)
            if relative == Self.manifestFilename { continue }
            let data = try DesktopWorkflowFilesystem.requiredBoundedRegularData(
                at: url,
                maximumBytes: 128 * 1_024 * 1_024,
                mapped: true,
                failure: DesktopWorkflowHostFrameworkError.invalidContract("extension component is unavailable")
            )
            total += data.count
            guard total <= maximumPackageBytes,
                  manifest.components.first(where: { $0.path == relative })?.sha256
                    == DesktopWorkflowStructuredValue.digest(data) else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("extension component digest does not match")
            }
        }
        guard discovered == declared else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("extension package is missing a declared component")
        }
        let digestInput = manifest.components.sorted { $0.path < $1.path }
            .map { "\($0.path)\u{001f}\($0.sha256)" }.joined(separator: "\n")
        return DesktopWorkflowExtensionInspection(
            manifest: manifest,
            packageDigest: DesktopWorkflowStructuredValue.digest(Data(digestInput.utf8)),
            totalBytes: total
        )
    }
}
