import CryptoKit
import Foundation

public enum DesktopWorkflowRuntimeClaimState: String, Codable, Equatable, Sendable {
    case active
    case released
    case expired
    case cancelled
}

public struct DesktopWorkflowRuntimeClaimRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var runID: String
    public var ownerID: String
    public var state: DesktopWorkflowRuntimeClaimState
    public var claimedAtUnixMillis: Int64
    public var heartbeatAtUnixMillis: Int64
    public var leaseDeadlineUnixMillis: Int64
    public var releasedAtUnixMillis: Int64?
}

public struct DesktopWorkflowCapabilityInvocation: Equatable, Sendable {
    public let workflowID: String
    public let workItemID: String
    public let episodeID: String
    public let runID: String
    public let step: DesktopWorkflowStepDefinition
    public let contextSnapshotID: String?
    public let input: Data
    public let artifactInputs: [DesktopWorkflowCapabilityArtifactInput]
    public let stateInputs: [DesktopWorkflowCapabilityStateInput]
    public let contextSnapshot: DesktopWorkflowContextSnapshotRecord?

}

public enum DesktopWorkflowCapabilityInvocationResult: Equatable, Sendable {
    case completed(
        output: Data,
        artifactIDs: [String],
        commitProposal: DesktopWorkflowCapabilityCommitProposal = .init(),
        artifactMetadata: [DesktopWorkflowStoredArtifact] = [],
        executionEvidence: DesktopWorkflowCapabilityExecutionEvidence = .init()
    )
    case waiting(reason: String)
}

public protocol DesktopWorkflowCapabilityInvoking: Sendable {
    func invoke(
        _ invocation: DesktopWorkflowCapabilityInvocation,
        installation: DesktopWorkflowCapabilityInstallationRecord
    ) async throws -> DesktopWorkflowCapabilityInvocationResult
}

public actor DesktopWorkflowCapabilityRouter: DesktopWorkflowCapabilityInvoking {
    public typealias Handler = @Sendable (
        DesktopWorkflowCapabilityInvocation,
        DesktopWorkflowCapabilityInstallationRecord
    ) async throws -> DesktopWorkflowCapabilityInvocationResult

    private let fallback: any DesktopWorkflowCapabilityInvoking
    private var handlers: [String: Handler] = [:]

    public init(fallback: any DesktopWorkflowCapabilityInvoking) {
        self.fallback = fallback
    }

    public func register(capabilityID: String, handler: @escaping Handler) {
        guard DesktopWorkflowBuiltinCapabilities.identifiers.contains(capabilityID) else { return }
        handlers[capabilityID] = handler
    }

    public func unregister(capabilityID: String) {
        handlers.removeValue(forKey: capabilityID)
    }

    public func invoke(
        _ invocation: DesktopWorkflowCapabilityInvocation,
        installation: DesktopWorkflowCapabilityInstallationRecord
    ) async throws -> DesktopWorkflowCapabilityInvocationResult {
        if installation.runtime == .builtIn {
            guard installation.trust == .kanameBuiltIn,
                  let handler = handlers[installation.capabilityID] else {
                throw DesktopWorkflowCapabilityError.executionUnavailable
            }
            return try await handler(invocation, installation)
        }
        return try await fallback.invoke(invocation, installation: installation)
    }

    public func invoke(
        workflowID: String,
        workItemID: String,
        episodeID: String,
        runID: String,
        step: DesktopWorkflowStepDefinition,
        contextSnapshotID: String?,
        input: Data,
        artifactInputs: [DesktopWorkflowCapabilityArtifactInput],
        stateInputs: [DesktopWorkflowCapabilityStateInput],
        contextSnapshot: DesktopWorkflowContextSnapshotRecord?,
        installation: DesktopWorkflowCapabilityInstallationRecord
    ) async throws -> DesktopWorkflowCapabilityInvocationResult {
        try await invoke(
            DesktopWorkflowCapabilityInvocation(
                workflowID: workflowID, workItemID: workItemID, episodeID: episodeID, runID: runID,
                step: step, contextSnapshotID: contextSnapshotID, input: input,
                artifactInputs: artifactInputs, stateInputs: stateInputs, contextSnapshot: contextSnapshot
            ),
            installation: installation
        )
    }
}

public struct DesktopWorkflowInstalledCapabilityInvoker: DesktopWorkflowCapabilityInvoking, Sendable {
    public let capabilityStore: DesktopWorkflowCapabilityStore
    public let scratchRoot: URL
    public let workflowInstallationsRoot: URL?
    public let processRunner: DesktopWorkflowCapabilityProcessRunner

    public init(
        capabilityStore: DesktopWorkflowCapabilityStore,
        scratchRoot: URL,
        workflowInstallationsRoot: URL? = nil,
        processRunner: DesktopWorkflowCapabilityProcessRunner = .init()
    ) {
        self.capabilityStore = capabilityStore
        self.scratchRoot = scratchRoot.standardizedFileURL
        self.workflowInstallationsRoot = workflowInstallationsRoot?.standardizedFileURL
        self.processRunner = processRunner
    }

    public func invoke(
        _ invocation: DesktopWorkflowCapabilityInvocation,
        installation: DesktopWorkflowCapabilityInstallationRecord
    ) async throws -> DesktopWorkflowCapabilityInvocationResult {
        guard installation.enabled else { throw DesktopWorkflowCapabilityError.packageUnavailable }
        let manifest = try capabilityStore.manifest(for: installation)
        switch manifest.runtime {
        case .builtIn:
            throw DesktopWorkflowCapabilityError.executionUnavailable
        case .isolatedProcess:
            let directory = capabilityStore.installationDirectory(
                capabilityID: installation.capabilityID,
                version: installation.version
            )
            let result = try await Task.detached(priority: .userInitiated) {
                try processRunner.execute(
                    manifest: manifest,
                    installationDirectory: directory,
                    input: invocation.input,
                    artifactInputs: invocation.artifactInputs,
                    stateInputs: invocation.stateInputs,
                    contextSnapshot: invocation.contextSnapshot,
                    scratchRoot: scratchRoot
                )
            }.value
            var metadata: [DesktopWorkflowStoredArtifact] = []
            if !result.artifacts.isEmpty {
                guard let workflowInstallationsRoot else { throw DesktopWorkflowCapabilityError.artifactInvalid }
                let storage = DesktopWorkflowStorage(
                    installationRoot: workflowInstallationsRoot
                        .appendingPathComponent(invocation.workflowID, isDirectory: true)
                )
                let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
                for artifact in result.artifacts {
                    let stored = try storage.importArtifact(
                        data: artifact.data,
                        filename: URL(fileURLWithPath: artifact.relativePath).lastPathComponent,
                        mediaType: "application/octet-stream",
                        createdAtUnixMillis: timestamp
                    )
                    guard stored.sha256 == artifact.sha256 else { throw DesktopWorkflowCapabilityError.artifactInvalid }
                    metadata.append(stored)
                }
            }
            return .completed(
                output: result.output, artifactIDs: result.artifacts.map(\.sha256),
                commitProposal: result.commitProposal, artifactMetadata: metadata,
                executionEvidence: .init(
                    standardOutput: result.standardOutput,
                    standardError: result.standardError,
                    elapsedMilliseconds: result.elapsedMilliseconds
                )
            )
        }
    }
}

public enum DesktopWorkflowExecutionDisposition: Equatable, Sendable {
    case completedStep(stepID: String, output: Data)
    case waiting(stepID: String, reason: String)
    case completedRun
    case failed(stepID: String, reason: String)
    case unavailable(reason: String)
}

@MainActor
public final class DesktopWorkflowRuntime {
    private let model: DesktopAppModel
    private let invoker: any DesktopWorkflowCapabilityInvoking
    private let ownerID: String
    private let leaseMilliseconds: Int64
    private let workflowInstallationsRoot: URL?

    public init(
        model: DesktopAppModel,
        invoker: any DesktopWorkflowCapabilityInvoking,
        ownerID: String = "kaname.desktop.workflow-runtime",
        leaseMilliseconds: Int64 = 30_000,
        workflowInstallationsRoot: URL? = nil
    ) {
        self.model = model
        self.invoker = invoker
        self.ownerID = ownerID
        self.leaseMilliseconds = max(5_000, leaseMilliseconds)
        self.workflowInstallationsRoot = workflowInstallationsRoot?.standardizedFileURL
    }

    public func executeNext(runID: String, input: Data) async -> DesktopWorkflowExecutionDisposition {
        let inputDigest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        guard let claimID = model.claimWorkflowRun(
            runID: runID,
            ownerID: ownerID,
            leaseMilliseconds: leaseMilliseconds
        ) else {
            return .unavailable(reason: "Another worker owns this run or the run is no longer executable.")
        }
        let heartbeat = _Concurrency.Task { [weak model] in
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .milliseconds(max(1_000, leaseMilliseconds / 3)))
                guard !_Concurrency.Task.isCancelled, let model,
                      model.heartbeatWorkflowRunClaim(
                          id: claimID,
                          ownerID: ownerID,
                          leaseMilliseconds: leaseMilliseconds
                      ) else { return }
            }
        }
        defer {
            heartbeat.cancel()
            _ = model.releaseWorkflowRunClaim(id: claimID, ownerID: ownerID)
        }
        guard let run = model.snapshot.operations.workflows.runs.first(where: { $0.id == runID }),
              let workItem = model.snapshot.operations.workflows.workItems.first(where: { $0.id == run.workItemID }),
              let revision = model.snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }) else {
            return .unavailable(reason: "The durable workflow identity is incomplete.")
        }
        guard let step = model.nextWorkflowStep(runID: runID) else {
            return model.completeWorkflowRun(id: runID)
                ? .completedRun
                : .unavailable(reason: "The run has no dispatchable step.")
        }
        if step.kind == .requestApproval {
            guard let attemptID = model.beginWorkflowStep(runID: runID, stepID: step.id, inputDigest: inputDigest),
                  revision.schemaVersion < 2 || model.recordWorkflowTransition(
                      runID: runID, fromStepID: step.id, outcome: .approved, value: input
                  ) != nil,
                  model.completeWorkflowStep(attemptID: attemptID, outputDigest: inputDigest) else {
                return .failed(stepID: step.id, reason: "Kaname could not commit the approval barrier.")
            }
            return .completedStep(stepID: step.id, output: input)
        }
        if [.humanReview, .waitForEmail].contains(step.kind) {
            let reason = waitingReason(for: step.kind)
            guard let attemptID = model.beginWorkflowStep(runID: runID, stepID: step.id, inputDigest: inputDigest) else {
                return .failed(stepID: step.id, reason: "Kaname could not persist the waiting stage.")
            }
            if step.kind == .humanReview, step.reviewContract != nil,
               model.createWorkflowReviewRequest(runID: runID, stepID: step.id, proposedValue: input) == nil {
                _ = model.completeWorkflowStep(
                    attemptID: attemptID, outputDigest: nil,
                    error: "Kaname could not create the schema-driven review request."
                )
                return .failed(stepID: step.id, reason: "Kaname could not create the schema-driven review request.")
            }
            if step.kind == .waitForEmail, step.waitContract != nil,
               model.createWorkflowWaitSubscription(runID: runID, stepID: step.id, input: input) == nil {
                _ = model.completeWorkflowStep(
                    attemptID: attemptID, outputDigest: nil,
                    error: "Kaname could not create the durable event subscription."
                )
                return .failed(stepID: step.id, reason: "Kaname could not create the durable event subscription.")
            }
            _ = model.interruptWorkflowStepForHost(attemptID: attemptID, reason: reason)
            return .waiting(stepID: step.id, reason: reason)
        }
        guard let attemptID = model.beginWorkflowStep(runID: runID, stepID: step.id, inputDigest: inputDigest) else {
            return .unavailable(reason: "Kaname could not begin the next durable step.")
        }
        let declaredInputs: (artifacts: [DesktopWorkflowCapabilityArtifactInput], state: [DesktopWorkflowCapabilityStateInput])
        do {
            declaredInputs = try workflowInputs(step: step, workItem: workItem, run: run)
        } catch {
            let reason = String(error.localizedDescription.prefix(8_192))
            if let failureValue = model.routeWorkflowStepFailure(attemptID: attemptID, error: reason) {
                return .completedStep(stepID: step.id, output: failureValue)
            }
            _ = model.completeWorkflowStep(attemptID: attemptID, outputDigest: nil, error: reason)
            return .failed(stepID: step.id, reason: reason)
        }
        if step.kind == .complete {
            guard model.completeWorkflowStep(attemptID: attemptID, outputDigest: inputDigest),
                  model.completeWorkflowRun(id: runID) else {
                return .failed(stepID: step.id, reason: "Kaname could not finalize the completed run.")
            }
            return .completedRun
        }
        guard let capabilityID = step.capabilityID else {
            let structuralKinds: Set<DesktopWorkflowStepKind> = [.classifyEvent, .correlateWork, .branch, .registerArtifact]
            guard structuralKinds.contains(step.kind) else {
                let reason = "The step has no registered capability binding."
                _ = model.completeWorkflowStep(attemptID: attemptID, outputDigest: nil, error: reason)
                return .failed(stepID: step.id, reason: reason)
            }
            if revision.schemaVersion >= 2 {
                let outcome: DesktopWorkflowTransitionOutcome
                if step.kind == .branch {
                    outcome = DesktopWorkflowGraphResolver.transition(from: step, outcome: .matched, value: input) == nil
                        ? .notMatched : .matched
                } else {
                    outcome = .succeeded
                }
                guard model.recordWorkflowTransition(
                    runID: runID, fromStepID: step.id, outcome: outcome, value: input
                ) != nil else {
                    _ = model.completeWorkflowStep(
                        attemptID: attemptID, outputDigest: nil,
                        error: "No declared graph transition matched this structured value."
                    )
                    return .failed(stepID: step.id, reason: "No declared graph transition matched this structured value.")
                }
            }
            _ = model.completeWorkflowStep(attemptID: attemptID, outputDigest: inputDigest)
            return .completedStep(stepID: step.id, output: input)
        }
        guard revision.permissions.capabilityIDs.contains(capabilityID),
              let installation = model.workflowCapabilityInstallation(capabilityID: capabilityID),
              installation.enabled,
              !installation.permissions.broadens(revision.permissions) else {
            let reason = "The reviewed capability binding is missing, disabled, or broader than this workflow revision."
            _ = model.completeWorkflowStep(attemptID: attemptID, outputDigest: nil, error: reason)
            return .failed(stepID: step.id, reason: reason)
        }
        do {
            let result = try await invoker.invoke(
                DesktopWorkflowCapabilityInvocation(
                    workflowID: workItem.workflowID,
                    workItemID: workItem.id,
                    episodeID: run.episodeID,
                    runID: run.id,
                    step: step,
                    contextSnapshotID: run.contextSnapshotID,
                    input: input,
                    artifactInputs: declaredInputs.artifacts,
                    stateInputs: declaredInputs.state,
                    contextSnapshot: run.contextSnapshotID.flatMap { id in
                        model.snapshot.operations.workflows.contextSnapshots.first { $0.id == id }
                    }
                ),
                installation: installation
            )
            switch result {
            case let .completed(output, artifactIDs, commitProposal, artifactMetadata, executionEvidence):
                if let policy = step.executionPolicy, output.count > policy.maximumOutputBytes {
                    throw DesktopWorkflowCapabilityError.outputInvalid
                }
                let digest = SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
                var durableArtifactIDs = artifactIDs
                var durableArtifactMetadata = artifactMetadata
                if let storage = workflowStorage(workflowID: workItem.workflowID) {
                    let stored = try storage.importArtifact(
                        data: output,
                        filename: "run-\(run.id)-step-\(step.id)-output.json",
                        mediaType: "application/json",
                        createdAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
                    )
                    guard stored.sha256 == digest else { throw DesktopWorkflowCapabilityError.artifactInvalid }
                    durableArtifactIDs.append(stored.sha256)
                    durableArtifactMetadata.append(stored)
                }
                if revision.schemaVersion >= 2,
                   model.recordWorkflowTransition(
                       runID: runID, fromStepID: step.id, outcome: .succeeded, value: output
                   ) == nil {
                    _ = model.completeWorkflowStep(
                        attemptID: attemptID, outputDigest: nil,
                        error: "No declared graph transition matched the capability output."
                    )
                    return .failed(stepID: step.id, reason: "No declared graph transition matched the capability output.")
                }
                guard model.completeWorkflowStep(
                    attemptID: attemptID,
                    outputDigest: digest,
                    artifactIDs: durableArtifactIDs,
                    commitProposal: commitProposal,
                    artifactMetadata: durableArtifactMetadata
                ) else {
                    _ = model.completeWorkflowStep(
                        attemptID: attemptID, outputDigest: nil,
                        error: DesktopWorkflowDataPlaneError.stateConflict.localizedDescription
                    )
                    return .failed(stepID: step.id, reason: "Kaname could not commit the capability receipt.")
                }
                _ = model.recordWorkflowExecutionReceipt(
                    attemptID: attemptID, capabilityID: capabilityID, outputDigest: digest,
                    artifactDigests: durableArtifactIDs, evidence: executionEvidence
                )
                return .completedStep(stepID: step.id, output: output)
            case let .waiting(reason):
                _ = model.interruptWorkflowStepForHost(attemptID: attemptID, reason: reason)
                return .waiting(stepID: step.id, reason: reason)
            }
        } catch {
            let reason = String(error.localizedDescription.prefix(8_192))
            if let failureValue = model.routeWorkflowStepFailure(attemptID: attemptID, error: reason) {
                return .completedStep(stepID: step.id, output: failureValue)
            }
            _ = model.completeWorkflowStep(attemptID: attemptID, outputDigest: nil, error: reason)
            return .failed(stepID: step.id, reason: reason)
        }
    }

    public func executeUntilBlocked(
        runID: String,
        initialInput: Data,
        maximumSteps: Int = 64
    ) async -> DesktopWorkflowExecutionDisposition {
        var input = durablePriorOutput(runID: runID) ?? initialInput
        for _ in 0..<min(max(1, maximumSteps), 64) {
            let disposition = await executeNext(runID: runID, input: input)
            switch disposition {
            case let .completedStep(_, output):
                input = output
            default:
                return disposition
            }
        }
        return .unavailable(reason: "The bounded interpreter reached its 64-step dispatch limit.")
    }

    private func waitingReason(for kind: DesktopWorkflowStepKind) -> String {
        switch kind {
        case .humanReview: "Human review is required before this run can continue."
        case .requestApproval: "Exact approval is required before the proposed effect can continue."
        case .waitForEmail: "The run is waiting for a correlated email episode."
        default: "The workflow is waiting for a host decision."
        }
    }

    private func durablePriorOutput(runID: String) -> Data? {
        guard let run = model.snapshot.operations.workflows.runs.first(where: { $0.id == runID }),
              let item = model.snapshot.operations.workflows.workItems.first(where: { $0.id == run.workItemID }),
              let storage = workflowStorage(workflowID: item.workflowID),
              let attempt = model.snapshot.operations.workflows.stepAttempts
                .filter({ $0.runID == runID && $0.state == .completed && $0.outputDigest != nil })
                .max(by: { ($0.startedAtUnixMillis, $0.attempt) < ($1.startedAtUnixMillis, $1.attempt) }),
              let digest = attempt.outputDigest,
              attempt.artifactIDs.contains(digest) else { return nil }
        return try? storage.artifactData(sha256: digest)
    }

    private func workflowInputs(
        step: DesktopWorkflowStepDefinition,
        workItem: DesktopWorkflowWorkItemRecord,
        run: DesktopWorkflowRunRecord
    ) throws -> (artifacts: [DesktopWorkflowCapabilityArtifactInput], state: [DesktopWorkflowCapabilityStateInput]) {
        let storage = workflowStorage(workflowID: workItem.workflowID)
        let roles = model.snapshot.operations.workflows.artifactRoles.filter {
            $0.workflowID == workItem.workflowID && $0.workItemID == workItem.id && $0.active
        }
        var artifacts: [DesktopWorkflowCapabilityArtifactInput] = []
        for declaration in step.artifactInputs ?? [] {
            guard let role = roles.first(where: { $0.role == declaration.role }), let storage else {
                if declaration.required { throw DesktopWorkflowDataPlaneError.requiredInputMissing }
                continue
            }
            artifacts.append(DesktopWorkflowCapabilityArtifactInput(
                role: role.role, artifactDigest: role.artifactDigest, filename: role.filename,
                mediaType: role.mediaType, data: try storage.artifactData(sha256: role.artifactDigest)
            ))
        }
        let accountScopeIDs = Set(model.snapshot.operations.workflows.conversationBindings.filter {
            $0.workItemID == workItem.id && $0.relationship != .detached
        }.map(\.accountID))
        let scopeContext = DesktopWorkflowResolvedDataScope(
            workflowID: workItem.workflowID, workItemID: workItem.id,
            runID: run.id, accountIDs: accountScopeIDs
        )
        let records = model.snapshot.operations.workflows.stateRecords.filter { $0.workflowID == workItem.workflowID }
        var state: [DesktopWorkflowCapabilityStateInput] = []
        for declaration in step.stateInputs ?? [] {
            let scope = declaration.scope ?? .installation
            guard let owner = scopeContext.identifier(for: scope) else {
                if declaration.required { throw DesktopWorkflowDataPlaneError.requiredInputMissing }
                continue
            }
            guard let record = records.first(where: {
                $0.matches(
                    workflowID: workItem.workflowID, scopeID: owner,
                    namespace: declaration.namespace, key: declaration.key
                )
            }) else {
                if declaration.required { throw DesktopWorkflowDataPlaneError.requiredInputMissing }
                continue
            }
            state.append(DesktopWorkflowCapabilityStateInput(record: record))
        }
        return (artifacts, state)
    }

    private func workflowStorage(workflowID: String) -> DesktopWorkflowStorage? {
        workflowInstallationsRoot.map {
            DesktopWorkflowStorage(installationRoot: $0.appendingPathComponent(workflowID, isDirectory: true))
        }
    }
}

public enum DesktopWorkflowMigrationReadinessState: String, Codable, Equatable, Sendable {
    case ready
    case attention
    case blocked
}

public struct DesktopWorkflowMigrationReadinessCheck: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let state: DesktopWorkflowMigrationReadinessState
}

public struct DesktopWorkflowMigrationReadinessReport: Codable, Equatable, Sendable {
    public let workflowID: String
    public let checks: [DesktopWorkflowMigrationReadinessCheck]

    public var isReady: Bool { !checks.contains { $0.state == .blocked } }
    public var blockedCount: Int { checks.filter { $0.state == .blocked }.count }
    public var attentionCount: Int { checks.filter { $0.state == .attention }.count }
}
