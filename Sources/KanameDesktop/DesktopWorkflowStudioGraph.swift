import CryptoKit
import Foundation

public enum DesktopWorkflowDataReferenceSource: String, Codable, CaseIterable, Equatable, Sendable {
    case trigger
    case configuration
    case binding
    case stepOutput
    case artifact
    case state
    case dataset
    case batchItem

    public var label: String {
        switch self {
        case .trigger: "Trigger input"
        case .configuration: "Installation configuration"
        case .binding: "Private binding"
        case .stepOutput: "Prior step output"
        case .artifact: "Artifact role"
        case .state: "Workflow state"
        case .dataset: "Dataset"
        case .batchItem: "Current batch item"
        }
    }
}

public struct DesktopWorkflowDataReference: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var source: DesktopWorkflowDataReferenceSource
    public var sourceID: String?
    public var pointer: String
    public var schema: String
    public var required: Bool

    public init(
        id: String,
        source: DesktopWorkflowDataReferenceSource,
        sourceID: String? = nil,
        pointer: String = "",
        schema: String = #"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}"#,
        required: Bool = true
    ) {
        self.id = id
        self.source = source
        self.sourceID = sourceID
        self.pointer = pointer
        self.schema = schema
        self.required = required
    }
}

public struct DesktopWorkflowDataMapping: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var targetPointer: String
    public var reference: DesktopWorkflowDataReference

    public init(id: String, targetPointer: String, reference: DesktopWorkflowDataReference) {
        self.id = id
        self.targetPointer = targetPointer
        self.reference = reference
    }
}

public enum DesktopWorkflowBatchAggregationPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case requireAll
    case allowPartial
    case stopOnFirstFailure

    public var label: String {
        switch self {
        case .requireAll: "Require every item"
        case .allowPartial: "Keep successful items"
        case .stopOnFirstFailure: "Stop on first failure"
        }
    }
}

public struct DesktopWorkflowBatchPolicy: Codable, Equatable, Sendable {
    public var itemsPointer: String
    public var maximumItems: Int
    public var maximumConcurrency: Int
    public var aggregation: DesktopWorkflowBatchAggregationPolicy

    public init(
        itemsPointer: String = "/items",
        maximumItems: Int = 100,
        maximumConcurrency: Int = 1,
        aggregation: DesktopWorkflowBatchAggregationPolicy = .requireAll
    ) {
        self.itemsPointer = itemsPointer
        self.maximumItems = maximumItems
        self.maximumConcurrency = maximumConcurrency
        self.aggregation = aggregation
    }
}

public enum DesktopWorkflowBatchItemState: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case unknown
    case cancelled
}

public struct DesktopWorkflowBatchItemRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var runID: String
    public var stepID: String
    public var ordinal: Int
    public var inputDigest: String
    public var outputDigest: String?
    public var state: DesktopWorkflowBatchItemState
    public var attempt: Int
    public var errorSummary: String?
    public var startedAtUnixMillis: Int64?
    public var completedAtUnixMillis: Int64?
}

public struct DesktopWorkflowCanvasNodePosition: Codable, Equatable, Identifiable, Sendable {
    public var id: String { stepID }
    public var stepID: String
    public var x: Double
    public var y: Double

    public init(stepID: String, x: Double, y: Double) {
        self.stepID = stepID
        self.x = x
        self.y = y
    }
}

public struct DesktopWorkflowStudioManifestMetadata: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var source: String
    public var license: String
    public var correlationSummary: String
    public var contextSummary: String
    public var completionSummary: String
    public var datasets: [DesktopWorkflowDatasetDefinition]?
    public var configurationSchema: String?
    public var configurationSchemaVersion: Int?
    public var manualRunInputSchema: String?
    public var bindingSlots: [DesktopWorkflowBindingSlotDefinition]?
    public var providerFeatures: [DesktopWorkflowProviderFeatureRequirement]?
    public var hostCompatibility: DesktopWorkflowHostCompatibility?
    public var dependencies: [DesktopWorkflowDependencyConstraint]?
    public var publisher: DesktopWorkflowPublisher?
    public var provenance: DesktopWorkflowPackageProvenance?
    public var uiHints: [DesktopWorkflowUIHint]?
    public var configurationMigrations: [DesktopWorkflowConfigurationMigration]?

    public static let newDraft = Self(
        schemaVersion: 3,
        source: "Kaname Workflow Studio",
        license: "Private",
        correlationSummary: "Configured in Workflow Studio",
        contextSummary: "Compile declared workflow context and current artifacts.",
        completionSummary: "Complete after declared validators, reviews, and effects.",
        datasets: nil,
        configurationSchema: nil,
        configurationSchemaVersion: nil,
        manualRunInputSchema: nil,
        bindingSlots: nil,
        providerFeatures: nil,
        hostCompatibility: .init(minimumWorkspaceSchema: 24),
        dependencies: nil,
        publisher: .init(name: "Local author", identifier: "local.author"),
        provenance: .init(buildSystem: "Kaname Workflow Studio"),
        uiHints: nil,
        configurationMigrations: nil
    )
}

public struct DesktopWorkflowStudioSnapshot: Codable, Equatable, Sendable {
    public var steps: [DesktopWorkflowStepDefinition]
    public var triggerKinds: [DesktopWorkflowTriggerKind]
    public var permissions: DesktopWorkflowPermissionEnvelope
    public var subflows: [DesktopWorkflowSubflowReference]
    public var canvasPositions: [DesktopWorkflowCanvasNodePosition]
    public var metadata: DesktopWorkflowStudioManifestMetadata
}

public enum DesktopWorkflowStudioDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case error
    case warning
}

public struct DesktopWorkflowStudioDiagnostic: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(severity.rawValue):\(path):\(message)" }
    public var severity: DesktopWorkflowStudioDiagnosticSeverity
    public var path: String
    public var message: String
}

public enum DesktopWorkflowStudioValidation {
    public static func diagnostics(
        steps: [DesktopWorkflowStepDefinition],
        metadata: DesktopWorkflowStudioManifestMetadata
    ) -> [DesktopWorkflowStudioDiagnostic] {
        var result: [DesktopWorkflowStudioDiagnostic] = []
        do { try DesktopWorkflowHostContractValidation.validateGraph(steps) }
        catch { result.append(.init(severity: .error, path: "/steps", message: error.localizedDescription)) }
        let stepIDs = Set(steps.map(\.id))
        for (index, step) in steps.enumerated() {
            do { try DesktopWorkflowHostContractValidation.validate(step: step, stepIDs: stepIDs) }
            catch { result.append(.init(severity: .error, path: "/steps/\(index)", message: error.localizedDescription)) }
            for (mappingIndex, mapping) in (step.inputMappings ?? []).enumerated() {
                let path = "/steps/\(index)/inputMappings/\(mappingIndex)"
                if !mapping.targetPointer.hasPrefix("/") {
                    result.append(.init(severity: .error, path: path + "/targetPointer", message: "Target must be a JSON Pointer."))
                }
                if !mapping.reference.pointer.isEmpty && !mapping.reference.pointer.hasPrefix("/") {
                    result.append(.init(severity: .error, path: path + "/reference/pointer", message: "Source must be a JSON Pointer."))
                }
                if let issue = DesktopWorkflowJSONSchemaValidator.schemaDiagnostics(Data(mapping.reference.schema.utf8), requireDeclaredDialect: true).first {
                    result.append(.init(severity: .error, path: path + "/reference/schema" + issue.path, message: issue.message))
                }
                if mapping.reference.source == .stepOutput {
                    guard let sourceID = mapping.reference.sourceID,
                          let sourceIndex = steps.firstIndex(where: { $0.id == sourceID }), sourceIndex < index else {
                        result.append(.init(severity: .error, path: path + "/reference/sourceID", message: "Step output mappings must reference an earlier reachable step."))
                        continue
                    }
                }
            }
        }
        if metadata.schemaVersion == 3 {
            if let schema = metadata.configurationSchema {
                for issue in DesktopWorkflowJSONSchemaValidator.schemaDiagnostics(Data(schema.utf8), requireDeclaredDialect: true) {
                    result.append(.init(severity: .error, path: "/configurationSchema" + issue.path, message: issue.message))
                }
            }
            if let schema = metadata.manualRunInputSchema {
                for issue in DesktopWorkflowJSONSchemaValidator.schemaDiagnostics(Data(schema.utf8), requireDeclaredDialect: true) {
                    result.append(.init(severity: .error, path: "/manualRunInputSchema" + issue.path, message: issue.message))
                }
            }
        }
        return result
    }
}

public enum DesktopWorkflowRunNodeState: String, Codable, CaseIterable, Equatable, Sendable {
    case notRun
    case queued
    case running
    case waiting
    case needsReview
    case retrying
    case succeeded
    case skipped
    case failed
    case outcomeUnknown
    case cancelled

    public var label: String {
        switch self {
        case .notRun: "Not run"
        case .queued: "Queued"
        case .running: "Running"
        case .waiting: "Waiting"
        case .needsReview: "Needs review"
        case .retrying: "Retrying"
        case .succeeded: "Succeeded"
        case .skipped: "Skipped"
        case .failed: "Failed"
        case .outcomeUnknown: "Outcome unknown—reconcile"
        case .cancelled: "Cancelled"
        }
    }
}

public struct DesktopWorkflowRunNodeProjection: Equatable, Identifiable, Sendable {
    public var id: String { stepID }
    public var stepID: String
    public var state: DesktopWorkflowRunNodeState
    public var attempt: Int
    public var elapsedMilliseconds: Int64?
    public var detail: String
    public var completedItems: Int
    public var totalItems: Int
    public var failedItems: Int
    public var unknownItems: Int
}

public struct DesktopWorkflowRunStepComparison: Equatable, Identifiable, Sendable {
    public var id: String { stepID }
    public var stepID: String
    public var leftState: DesktopWorkflowRunNodeState
    public var rightState: DesktopWorkflowRunNodeState
    public var inputChanged: Bool
    public var outputChanged: Bool
    public var durationDeltaMilliseconds: Int64?
    public var branchChanged: Bool
}

public enum DesktopWorkflowDebugAction: String, CaseIterable, Equatable, Sendable {
    case pauseBeforeStep
    case continueSimulation
    case retryFailedStep
    case restartFromCheckpoint
    case reprocessCurrentRevision
    case reconcileUnknownEffect
}

public struct DesktopWorkflowDebugEligibility: Equatable, Sendable {
    public var allowed: Set<DesktopWorkflowDebugAction>
    public var reasons: [DesktopWorkflowDebugAction: String]
}

public enum DesktopWorkflowRunProjection {
    public static func nodes(
        run: DesktopWorkflowRunRecord,
        revision: DesktopWorkflowRevisionRecord,
        attempts: [DesktopWorkflowStepAttemptRecord],
        transitions: [DesktopWorkflowTransitionRecord],
        waits: [DesktopWorkflowWaitSubscriptionRecord],
        reviews: [DesktopWorkflowReviewRequestRecord],
        effects: [DesktopWorkflowEffectRecord],
        batchItems: [DesktopWorkflowBatchItemRecord],
        now: Int64
    ) -> [DesktopWorkflowRunNodeProjection] {
        revision.steps.map { step in
            let relevant = attempts.filter { $0.runID == run.id && $0.stepID == step.id }
            let latest = relevant.max { $0.attempt < $1.attempt }
            let activeWait = waits.first { $0.runID == run.id && $0.stepID == step.id && $0.state == .active }
            let review = reviews.first { $0.runID == run.id && $0.stepID == step.id && $0.state == .pending }
            let unknown = effects.contains { $0.runID == run.id && $0.stepID == step.id && $0.state == .outcomeUnknown }
            let selected = transitions.contains { $0.runID == run.id && $0.toStepID == step.id }
            let items = batchItems.filter { $0.runID == run.id && $0.stepID == step.id }
            let state: DesktopWorkflowRunNodeState
            let detail: String
            if unknown { (state, detail) = (.outcomeUnknown, "Remote outcome must be reconciled before retry.") }
            else if review != nil { (state, detail) = (.needsReview, "A human decision is required.") }
            else if let activeWait { (state, detail) = (.waiting, "Waiting until \(activeWait.deadlineUnixMillis).") }
            else if latest?.state == .running { (state, detail) = (relevant.count > 1 ? .retrying : .running, "Attempt \(latest?.attempt ?? 1) is active.") }
            else if latest?.state == .completed { (state, detail) = (.succeeded, "Completed with durable evidence.") }
            else if latest?.state == .failed { (state, detail) = (.failed, latest?.errorSummary ?? "The step failed.") }
            else if latest?.state == .cancelled { (state, detail) = (.cancelled, "Cancelled.") }
            else if selected || run.currentStepID == step.id { (state, detail) = (.queued, "Ready to run.") }
            else if !transitions.isEmpty { (state, detail) = (.skipped, "This branch was not selected.") }
            else { (state, detail) = (.notRun, "Not run.") }
            let elapsed = latest.map { max(0, ($0.completedAtUnixMillis ?? now) - $0.startedAtUnixMillis) }
            return .init(
                stepID: step.id, state: state, attempt: latest?.attempt ?? 0,
                elapsedMilliseconds: elapsed, detail: detail,
                completedItems: items.filter { $0.state == .succeeded }.count,
                totalItems: items.count,
                failedItems: items.filter { $0.state == .failed }.count,
                unknownItems: items.filter { $0.state == .unknown }.count
            )
        }
    }

    public static func compare(
        left: [DesktopWorkflowRunNodeProjection],
        right: [DesktopWorkflowRunNodeProjection],
        leftAttempts: [DesktopWorkflowStepAttemptRecord],
        rightAttempts: [DesktopWorkflowStepAttemptRecord],
        leftTransitions: [DesktopWorkflowTransitionRecord],
        rightTransitions: [DesktopWorkflowTransitionRecord]
    ) -> [DesktopWorkflowRunStepComparison] {
        let ids = Set(left.map(\.stepID)).union(right.map(\.stepID)).sorted()
        return ids.map { id in
            let lhs = left.first { $0.stepID == id }
            let rhs = right.first { $0.stepID == id }
            let la = leftAttempts.last { $0.stepID == id }
            let ra = rightAttempts.last { $0.stepID == id }
            let lt = leftTransitions.last { $0.fromStepID == id }
            let rt = rightTransitions.last { $0.fromStepID == id }
            return .init(
                stepID: id, leftState: lhs?.state ?? .notRun, rightState: rhs?.state ?? .notRun,
                inputChanged: la?.inputDigest != ra?.inputDigest,
                outputChanged: la?.outputDigest != ra?.outputDigest,
                durationDeltaMilliseconds: duration(ra).flatMap { rightDuration in duration(la).map { rightDuration - $0 } },
                branchChanged: lt?.toStepID != rt?.toStepID || lt?.outcome != rt?.outcome
            )
        }
    }

    public static func debugEligibility(
        step: DesktopWorkflowStepDefinition,
        projection: DesktopWorkflowRunNodeProjection,
        hasUnknownEffect: Bool
    ) -> DesktopWorkflowDebugEligibility {
        var allowed: Set<DesktopWorkflowDebugAction> = [.pauseBeforeStep, .continueSimulation, .reprocessCurrentRevision]
        var reasons: [DesktopWorkflowDebugAction: String] = [:]
        if projection.state == .failed && step.isIdempotent && !hasUnknownEffect { allowed.insert(.retryFailedStep) }
        else { reasons[.retryFailedStep] = hasUnknownEffect ? "Reconcile the unknown effect first." : "The step is not safely idempotent." }
        if [.succeeded, .failed, .cancelled].contains(projection.state) { allowed.insert(.restartFromCheckpoint) }
        else { reasons[.restartFromCheckpoint] = "A durable completed checkpoint is required." }
        if hasUnknownEffect { allowed.insert(.reconcileUnknownEffect) }
        else { reasons[.reconcileUnknownEffect] = "No unknown effect exists." }
        return .init(allowed: allowed, reasons: reasons)
    }

    private static func duration(_ attempt: DesktopWorkflowStepAttemptRecord?) -> Int64? {
        guard let attempt, let completed = attempt.completedAtUnixMillis else { return nil }
        return max(0, completed - attempt.startedAtUnixMillis)
    }
}

@MainActor
public extension DesktopAppModel {
    @discardableResult
    func queueWorkflowDebugRun(
        priorRunID: String,
        action: DesktopWorkflowDebugAction,
        stepID: String? = nil
    ) -> String? {
        guard let prior = snapshot.operations.workflows.runs.first(where: { $0.id == priorRunID }),
              let contextID = prior.contextSnapshotID,
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == prior.workflowRevisionID }) else {
            return nil
        }
        switch action {
        case .retryFailedStep:
            guard prior.state == .failed, let stepID,
                  let step = revision.steps.first(where: { $0.id == stepID }), step.isIdempotent,
                  snapshot.operations.workflows.stepAttempts.contains(where: {
                      $0.runID == priorRunID && $0.stepID == stepID && $0.state == .failed
                  }),
                  !snapshot.operations.workflows.effects.contains(where: {
                      $0.runID == priorRunID && $0.stepID == stepID && $0.state == .outcomeUnknown
                  }) else { return nil }
            return queueWorkflowRun(
                workItemID: prior.workItemID, episodeID: prior.episodeID, contextSnapshotID: contextID,
                retryMode: .failedStep, priorRunID: priorRunID, startStepID: stepID
            )
        case .restartFromCheckpoint:
            guard [.completed, .failed, .cancelled].contains(prior.state), let stepID,
                  snapshot.operations.workflows.stepAttempts.contains(where: {
                      $0.runID == priorRunID && $0.stepID == stepID && $0.state == .completed
                  }),
                  let next = snapshot.operations.workflows.transitionRecords.last(where: {
                      $0.runID == priorRunID && $0.fromStepID == stepID
                  })?.toStepID else { return nil }
            return queueWorkflowRun(
                workItemID: prior.workItemID, episodeID: prior.episodeID, contextSnapshotID: contextID,
                retryMode: .exactReplay, priorRunID: priorRunID, startStepID: next
            )
        case .reprocessCurrentRevision:
            guard [.completed, .failed, .cancelled].contains(prior.state) else { return nil }
            return queueWorkflowRun(
                workItemID: prior.workItemID, episodeID: prior.episodeID, contextSnapshotID: contextID,
                retryMode: .currentRevision, priorRunID: priorRunID
            )
        case .pauseBeforeStep, .continueSimulation, .reconcileUnknownEffect:
            return nil
        }
    }

    func prepareWorkflowBatch(runID: String, stepID: String, input: Data) throws -> [DesktopWorkflowBatchItemRecord] {
        guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
              let step = revision.steps.first(where: { $0.id == stepID }),
              let policy = step.batchPolicy else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("The batch step is unavailable.")
        }
        if !snapshot.operations.workflows.batchItems.filter({ $0.runID == runID && $0.stepID == stepID }).isEmpty {
            return snapshot.operations.workflows.batchItems
                .filter { $0.runID == runID && $0.stepID == stepID }.sorted { $0.ordinal < $1.ordinal }
        }
        guard let value = try DesktopWorkflowStructuredValue.value(at: policy.itemsPointer, in: input),
              let items = value as? [Any], items.count <= policy.maximumItems else {
            throw DesktopWorkflowHostFrameworkError.invalidContract("The batch input is not an array or exceeds its reviewed item limit.")
        }
        let records = try items.enumerated().map { ordinal, item in
            let data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            let digest = DesktopWorkflowStructuredValue.digest(data)
            let identity = DesktopWorkflowStructuredValue.digest(Data("\(runID):\(stepID):\(ordinal):\(digest)".utf8))
            return DesktopWorkflowBatchItemRecord(
                id: identity, runID: runID, stepID: stepID, ordinal: ordinal,
                inputDigest: digest, outputDigest: nil, state: .queued, attempt: 0,
                errorSummary: nil, startedAtUnixMillis: nil, completedAtUnixMillis: nil
            )
        }
        guard mutate({ $0.operations.workflows.batchItems.append(contentsOf: records) }) else {
            throw DesktopWorkflowDataPlaneError.stateConflict
        }
        return records
    }

    @discardableResult
    func updateWorkflowBatchItem(
        id: String,
        state: DesktopWorkflowBatchItemState,
        outputDigest: String? = nil,
        error: String? = nil
    ) -> Bool {
        let timestamp = now()
        return mutateRecord(at: \.operations.workflows.batchItems, id: id) { item in
            item.state = state
            if state == .running {
                item.attempt += 1
                item.startedAtUnixMillis = timestamp
                item.completedAtUnixMillis = nil
            } else if [.succeeded, .failed, .unknown, .cancelled].contains(state) {
                item.completedAtUnixMillis = timestamp
            }
            item.outputDigest = outputDigest
            item.errorSummary = error.map { String($0.prefix(2_048)) }
        }
    }

    func workflowRunProjection(runID: String, now timestamp: Int64? = nil) -> [DesktopWorkflowRunNodeProjection] {
        guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }) else { return [] }
        return DesktopWorkflowRunProjection.nodes(
            run: run, revision: revision,
            attempts: snapshot.operations.workflows.stepAttempts.filter { $0.runID == runID },
            transitions: snapshot.operations.workflows.transitionRecords.filter { $0.runID == runID },
            waits: snapshot.operations.workflows.waitSubscriptions.filter { $0.runID == runID },
            reviews: snapshot.operations.workflows.reviewRequests.filter { $0.runID == runID },
            effects: snapshot.operations.workflows.effects.filter { $0.runID == runID },
            batchItems: snapshot.operations.workflows.batchItems.filter { $0.runID == runID },
            now: timestamp ?? now()
        )
    }

    func compareWorkflowRuns(leftRunID: String, rightRunID: String) -> [DesktopWorkflowRunStepComparison] {
        let leftAttempts = snapshot.operations.workflows.stepAttempts.filter { $0.runID == leftRunID }
        let rightAttempts = snapshot.operations.workflows.stepAttempts.filter { $0.runID == rightRunID }
        return DesktopWorkflowRunProjection.compare(
            left: workflowRunProjection(runID: leftRunID), right: workflowRunProjection(runID: rightRunID),
            leftAttempts: leftAttempts, rightAttempts: rightAttempts,
            leftTransitions: snapshot.operations.workflows.transitionRecords.filter { $0.runID == leftRunID },
            rightTransitions: snapshot.operations.workflows.transitionRecords.filter { $0.runID == rightRunID }
        )
    }
}
