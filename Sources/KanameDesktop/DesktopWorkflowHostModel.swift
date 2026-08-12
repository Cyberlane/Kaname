import Foundation

public extension DesktopAppModel {
    // MARK: Typed graph

    @discardableResult
    func recordWorkflowTransition(
        runID: String,
        fromStepID: String,
        outcome: DesktopWorkflowTransitionOutcome,
        value: Data
    ) -> String? {
        guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
              revision.schemaVersion >= 2,
              let step = revision.steps.first(where: { $0.id == fromStepID }),
              let transition = DesktopWorkflowGraphResolver.transition(from: step, outcome: outcome, value: value) else {
            return nil
        }
        if let existing = snapshot.operations.workflows.transitionRecords.first(where: {
            $0.runID == runID && $0.fromStepID == fromStepID
        }) {
            return existing.toStepID == transition.targetStepID && existing.outcome == outcome ? existing.toStepID : nil
        }
        let timestamp = now()
        let record = DesktopWorkflowTransitionRecord(
            id: UUID().uuidString.lowercased(), runID: runID, fromStepID: fromStepID,
            toStepID: transition.targetStepID, outcome: outcome,
            decisionDigest: DesktopWorkflowStructuredValue.digest(value), createdAtUnixMillis: timestamp
        )
        guard mutate({ $0.operations.workflows.transitionRecords.append(record) }) else { return nil }
        return transition.targetStepID
    }

    func routeWorkflowStepFailure(attemptID: String, error: String) -> Data? {
        guard let attempt = snapshot.operations.workflows.stepAttempts.first(where: {
            $0.id == attemptID && $0.state == .running
        }), let run = snapshot.operations.workflows.runs.first(where: { $0.id == attempt.runID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
              revision.schemaVersion >= 2,
              let step = revision.steps.first(where: { $0.id == attempt.stepID }) else { return nil }
        let failureValue: Data
        do {
            failureValue = try JSONSerialization.data(
                withJSONObject: ["error": String(error.prefix(8_192))], options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch { return nil }
        guard let transition = DesktopWorkflowGraphResolver.transition(
            from: step, outcome: .failed, value: failureValue
        ) else { return nil }
        let timestamp = now()
        let digest = DesktopWorkflowStructuredValue.digest(failureValue)
        guard mutate({ state in
            guard let attemptIndex = state.operations.workflows.stepAttempts.firstIndex(where: { $0.id == attemptID }),
                  let runIndex = state.operations.workflows.runs.firstIndex(where: { $0.id == run.id }) else { return }
            state.operations.workflows.stepAttempts[attemptIndex].state = .failed
            state.operations.workflows.stepAttempts[attemptIndex].outputDigest = digest
            state.operations.workflows.stepAttempts[attemptIndex].errorSummary = String(error.prefix(8_192))
            state.operations.workflows.stepAttempts[attemptIndex].completedAtUnixMillis = timestamp
            state.operations.workflows.runs[runIndex].state = .queued
            state.operations.workflows.runs[runIndex].currentStepID = nil
            state.operations.workflows.transitionRecords.append(.init(
                id: UUID().uuidString.lowercased(), runID: run.id, fromStepID: step.id,
                toStepID: transition.targetStepID, outcome: .failed,
                decisionDigest: digest, createdAtUnixMillis: timestamp
            ))
            state.setWorkflowWorkItemPresentation(
                id: run.workItemID, state: .preparing,
                nextAction: "The failed stage followed its declared error route.", updatedAtUnixMillis: timestamp
            )
            state.appendAudit(
                domain: "workflow-runtime", action: "handled-failure", target: "\(run.id)/\(step.id)",
                state: .failed, detail: "Failure evidence was preserved and routed to \(transition.targetStepID).",
                recordedAtUnixMillis: timestamp
            )
        }) else { return nil }
        return failureValue
    }

    // MARK: Structured review

    var pendingWorkflowReviews: [DesktopWorkflowReviewRequestRecord] {
        snapshot.operations.workflows.reviewRequests.filter { $0.state == .pending }
            .sorted { ($0.createdAtUnixMillis, $0.id) < ($1.createdAtUnixMillis, $1.id) }
    }

    @discardableResult
    func createWorkflowReviewRequest(
        runID: String,
        stepID: String,
        proposedValue: Data
    ) -> String? {
        guard proposedValue.count <= 8 * 1_024 * 1_024,
              let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID }),
              let item = snapshot.operations.workflows.workItems.first(where: { $0.id == run.workItemID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
              let step = revision.steps.first(where: { $0.id == stepID }),
              let contract = step.reviewContract,
              DesktopWorkflowJSONSchemaValidator.validates(instance: proposedValue, against: contract.inputSchema) else {
            return nil
        }
        if let existing = snapshot.operations.workflows.reviewRequests.first(where: {
            $0.runID == runID && $0.stepID == stepID && $0.state == .pending
        }) { return existing.id }
        let timestamp = now()
        let request = DesktopWorkflowReviewRequestRecord(
            id: UUID().uuidString.lowercased(), workflowID: item.workflowID, workItemID: item.id,
            episodeID: run.episodeID, runID: runID, stepID: stepID, contract: contract,
            proposedValue: proposedValue, proposedValueDigest: DesktopWorkflowStructuredValue.digest(proposedValue),
            state: .pending, selectedActionID: nil, resolvedValue: nil, resolvedValueDigest: nil,
            reviewer: nil, createdAtUnixMillis: timestamp, resolvedAtUnixMillis: nil
        )
        guard mutate({ state in
            state.appendWorkflowHostRecord(request, to: \.reviewRequests)
            state.setWorkflowWorkItemPresentation(
                id: item.id, state: .needsAttention,
                nextAction: contract.title, updatedAtUnixMillis: timestamp
            )
        }) else { return nil }
        return request.id
    }

    func resolveWorkflowReview(
        id: String,
        actionID: String,
        value: Data,
        reviewer: String
    ) -> Bool {
        let cleanReviewer = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanReviewer.isEmpty, cleanReviewer.utf8.count <= 240,
              let request = snapshot.operations.workflows.reviewRequests.first(where: { $0.id == id && $0.state == .pending }),
              let action = request.contract.actions.first(where: { $0.id == actionID }),
              value.count <= 8 * 1_024 * 1_024,
              DesktopWorkflowJSONSchemaValidator.validates(instance: value, against: request.contract.outputSchema),
              let run = snapshot.operations.workflows.runs.first(where: { $0.id == request.runID && $0.state == .waiting }),
              let attempt = snapshot.operations.workflows.stepAttempts
                .filter({ $0.runID == request.runID && $0.stepID == request.stepID && $0.state == .waiting })
                .max(by: { $0.attempt < $1.attempt }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
              let step = revision.steps.first(where: { $0.id == request.stepID }) else { return false }
        let outcome: DesktopWorkflowTransitionOutcome = switch action.kind {
        case .approve: .approved
        case .reject, .escalate: .rejected
        case .edit: .edited
        case .select: .selected
        case .acknowledge: .acknowledged
        }
        let target = revision.schemaVersion >= 2
            ? DesktopWorkflowGraphResolver.transition(from: step, outcome: outcome, value: value)?.targetStepID
            : nil
        guard revision.schemaVersion < 2 || target != nil else { return false }
        let timestamp = now()
        let digest = DesktopWorkflowStructuredValue.digest(value)
        return mutate { state in
            guard let requestIndex = state.operations.workflows.reviewRequests.firstIndex(where: { $0.id == id }) else { return }
            state.operations.workflows.reviewRequests[requestIndex].state = .resolved
            state.operations.workflows.reviewRequests[requestIndex].selectedActionID = actionID
            state.operations.workflows.reviewRequests[requestIndex].resolvedValue = value
            state.operations.workflows.reviewRequests[requestIndex].resolvedValueDigest = digest
            state.operations.workflows.reviewRequests[requestIndex].reviewer = cleanReviewer
            state.operations.workflows.reviewRequests[requestIndex].resolvedAtUnixMillis = timestamp
            state.applyWorkflowHostStepTransition(
                attemptID: attempt.id, runID: run.id, workItemID: run.workItemID,
                stepID: request.stepID, transition: .complete(outputDigest: digest, artifactIDs: []), timestamp: timestamp
            )
            if let target {
                state.operations.workflows.transitionRecords.append(.init(
                    id: UUID().uuidString.lowercased(), runID: run.id, fromStepID: request.stepID,
                    toStepID: target, outcome: outcome, decisionDigest: digest, createdAtUnixMillis: timestamp
                ))
            }
            if action.kind == .edit && request.contract.invalidateValidationOnEdit {
                for index in state.operations.workflows.validations.indices
                    where state.operations.workflows.validations[index].runID == run.id {
                    state.operations.workflows.validations[index].outcome = .notRun
                    state.operations.workflows.validations[index].waiverDecisionID = nil
                    state.operations.workflows.validations[index].summary =
                        "Invalidated by a structured review edit; validation must run again."
                }
            }
            state.setWorkflowWorkItemPresentation(
                id: run.workItemID, state: .preparing,
                nextAction: "Structured review recorded. Resume the workflow run.", updatedAtUnixMillis: timestamp
            )
            state.appendAudit(
                domain: "workflow-review", action: action.kind.rawValue, target: "\(run.id)/\(request.stepID)",
                state: .completed, detail: "Review decision bound to output digest \(digest.prefix(12)).",
                recordedAtUnixMillis: timestamp
            )
        }
    }

    // MARK: Resumable waits

    var activeWorkflowWaits: [DesktopWorkflowWaitSubscriptionRecord] {
        snapshot.operations.workflows.waitSubscriptions.filter { $0.state == .active }
            .sorted { ($0.deadlineUnixMillis, $0.id) < ($1.deadlineUnixMillis, $1.id) }
    }

    @discardableResult
    func createWorkflowWaitSubscription(runID: String, stepID: String, input: Data) -> String? {
        guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID }),
              let item = snapshot.operations.workflows.workItems.first(where: { $0.id == run.workItemID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
              let step = revision.steps.first(where: { $0.id == stepID }),
              let contract = step.waitContract else { return nil }
        if let existing = snapshot.operations.workflows.waitSubscriptions.first(where: {
            $0.runID == runID && $0.stepID == stepID && $0.state == .active
        }) { return existing.id }
        let accountID = contract.accountPointer.flatMap { try? DesktopWorkflowStructuredValue.string(at: $0, in: input) } ?? nil
        let conversationID = contract.conversationPointer.flatMap { try? DesktopWorkflowStructuredValue.string(at: $0, in: input) } ?? nil
        let correlation = contract.correlationPointer.flatMap { try? DesktopWorkflowStructuredValue.string(at: $0, in: input) } ?? nil
        let timestamp = now()
        let subscription = DesktopWorkflowWaitSubscriptionRecord(
            id: UUID().uuidString.lowercased(), workflowID: item.workflowID, workItemID: item.id,
            episodeID: run.episodeID, runID: run.id, stepID: stepID, connectorID: contract.connectorID,
            source: contract.source, accountID: accountID, conversationID: conversationID,
            correlationPointer: contract.correlationPointer, correlationValue: correlation,
            state: .active, createdAtUnixMillis: timestamp,
            deadlineUnixMillis: timestamp + Int64(contract.timeoutSeconds) * 1_000,
            resolvedEventID: nil, resolvedAtUnixMillis: nil
        )
        guard mutate({ state in
            if contract.supersedePrior {
                for index in state.operations.workflows.waitSubscriptions.indices
                    where state.operations.workflows.waitSubscriptions[index].workItemID == item.id
                        && state.operations.workflows.waitSubscriptions[index].stepID == stepID
                        && state.operations.workflows.waitSubscriptions[index].state == .active {
                    state.operations.workflows.waitSubscriptions[index].state = .superseded
                    state.operations.workflows.waitSubscriptions[index].resolvedAtUnixMillis = timestamp
                }
            }
            state.operations.workflows.waitSubscriptions.append(subscription)
        }) else { return nil }
        return subscription.id
    }

    @discardableResult
    func resolveWorkflowWaitSubscriptions(eventID: String, payload: Data) -> [String] {
        guard let event = snapshot.operations.workflows.externalEvents.first(where: { $0.id == eventID }) else { return [] }
        let timestamp = now()
        let matching = activeWorkflowWaits.filter { wait in
            wait.deadlineUnixMillis >= timestamp
                && wait.source == event.source
                && (wait.accountID == nil || wait.accountID == event.accountID)
                && (wait.conversationID == nil || wait.conversationID == event.conversationID)
                && (wait.correlationValue == nil || wait.correlationPointer.flatMap {
                    try? DesktopWorkflowStructuredValue.string(at: $0, in: payload)
                } == wait.correlationValue)
        }
        var resolved: [String] = []
        for wait in matching {
            guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == wait.runID && $0.state == .waiting }),
                  let attempt = snapshot.operations.workflows.stepAttempts
                    .filter({ $0.runID == wait.runID && $0.stepID == wait.stepID && $0.state == .waiting })
                    .max(by: { $0.attempt < $1.attempt }),
                  let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
                  let step = revision.steps.first(where: { $0.id == wait.stepID }) else { continue }
            let target = revision.schemaVersion >= 2
                ? DesktopWorkflowGraphResolver.transition(from: step, outcome: .succeeded, value: payload)?.targetStepID
                : nil
            guard revision.schemaVersion < 2 || target != nil else { continue }
            let digest = DesktopWorkflowStructuredValue.digest(payload)
            if mutate({ state in
                guard let index = state.operations.workflows.waitSubscriptions.firstIndex(where: { $0.id == wait.id }) else { return }
                state.operations.workflows.waitSubscriptions[index].state = .resolved
                state.operations.workflows.waitSubscriptions[index].resolvedEventID = eventID
                state.operations.workflows.waitSubscriptions[index].resolvedAtUnixMillis = timestamp
                state.applyWorkflowHostStepTransition(
                    attemptID: attempt.id, runID: run.id, workItemID: run.workItemID,
                    stepID: wait.stepID, transition: .complete(outputDigest: digest, artifactIDs: []), timestamp: timestamp
                )
                if let target {
                    state.operations.workflows.transitionRecords.append(.init(
                        id: UUID().uuidString.lowercased(), runID: run.id, fromStepID: wait.stepID,
                        toStepID: target, outcome: .succeeded, decisionDigest: digest, createdAtUnixMillis: timestamp
                    ))
                }
                state.setWorkflowWorkItemPresentation(
                    id: run.workItemID, state: .preparing,
                    nextAction: "A correlated event resumed this workflow run.", updatedAtUnixMillis: timestamp
                )
            }) { resolved.append(wait.id) }
        }
        return resolved
    }

    @discardableResult
    func expireWorkflowWaits() -> Int {
        let timestamp = now()
        let expired = activeWorkflowWaits.filter { $0.deadlineUnixMillis < timestamp }
        return expired.reduce(into: 0) { count, wait in
            if expireWorkflowWait(wait, timestamp: timestamp) { count += 1 }
        }
    }

    private func expireWorkflowWait(_ wait: DesktopWorkflowWaitSubscriptionRecord, timestamp: Int64) -> Bool {
        mutate { state in
            guard let waitIndex = state.operations.workflows.waitSubscriptions.firstIndex(where: {
                $0.id == wait.id && $0.state == .active
            }) else { return }
            state.operations.workflows.waitSubscriptions[waitIndex].state = .timedOut
            state.operations.workflows.waitSubscriptions[waitIndex].resolvedAtUnixMillis = timestamp
            let run = state.operations.workflows.runs.first { $0.id == wait.runID }
            let attempt = state.operations.workflows.stepAttempts
                .filter { $0.runID == wait.runID && $0.stepID == wait.stepID && $0.state == .waiting }
                .max { $0.attempt < $1.attempt }
            let revision = run.flatMap { currentRun in
                state.operations.workflows.revisions.first { $0.id == currentRun.workflowRevisionID }
            }
            let timeoutValue = Data("{\"timedOut\":true}".utf8)
            let target = revision?.steps.first(where: { $0.id == wait.stepID }).flatMap {
                DesktopWorkflowGraphResolver.transition(from: $0, outcome: .timedOut, value: timeoutValue)?.targetStepID
            }
            guard let run, let attempt, (revision?.schemaVersion ?? 0) >= 2, let target else {
                state.setWorkflowWorkItemPresentation(
                    id: wait.workItemID, state: .needsAttention,
                    nextAction: "The external wait timed out. Review retry or cancellation.", updatedAtUnixMillis: timestamp
                )
                return
            }
            let digest = DesktopWorkflowStructuredValue.digest(timeoutValue)
            state.applyWorkflowHostStepTransition(
                attemptID: attempt.id, runID: run.id, workItemID: run.workItemID,
                stepID: wait.stepID, transition: .complete(outputDigest: digest, artifactIDs: []), timestamp: timestamp
            )
            state.operations.workflows.transitionRecords.append(.init(
                id: UUID().uuidString.lowercased(), runID: run.id, fromStepID: wait.stepID,
                toStepID: target, outcome: .timedOut, decisionDigest: digest, createdAtUnixMillis: timestamp
            ))
            state.setWorkflowWorkItemPresentation(
                id: wait.workItemID, state: .preparing,
                nextAction: "The wait timed out and followed its declared timeout route.", updatedAtUnixMillis: timestamp
            )
        }
    }

    // MARK: Datasets

    func workflowDatasetRows(
        workflowID: String,
        datasetID: String,
        scopeID: String
    ) -> [DesktopWorkflowDatasetRowRecord] {
        snapshot.operations.workflows.datasetRows.filter {
            $0.workflowID == workflowID && $0.datasetID == datasetID && $0.scopeID == scopeID
        }.sorted { ($0.uniqueKey, $0.id) < ($1.uniqueKey, $1.id) }
    }

    @discardableResult
    func upsertWorkflowDataset(
        workflowID: String,
        runID: String,
        mutation: DesktopWorkflowDatasetMutation
    ) throws -> Int {
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == workflowID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == definition.currentRevisionID }),
              let dataset = revision.datasetDefinitions?.first(where: { $0.id == mutation.datasetID }),
              snapshot.operations.workflows.runs.contains(where: { run in
                  run.id == runID && snapshot.operations.workflows.workItems.contains {
                      $0.id == run.workItemID && $0.workflowID == workflowID
                  }
              }) else {
            throw DesktopWorkflowHostFrameworkError.datasetUnavailable
        }
        let existing = workflowDatasetRows(workflowID: workflowID, datasetID: dataset.id, scopeID: mutation.scopeID)
        let currentRevision = existing.map(\.revision).max() ?? 0
        if let expected = mutation.expectedRevision, expected != currentRevision {
            throw DesktopWorkflowHostFrameworkError.datasetConflict
        }
        guard mutation.rows.count <= dataset.maximumRows,
              mutation.rows.reduce(0, { $0 + $1.count }) <= 64 * 1_024 * 1_024 else {
            throw DesktopWorkflowHostFrameworkError.datasetLimitExceeded
        }
        var proposed = Dictionary(uniqueKeysWithValues: existing.map { ($0.uniqueKey, $0) })
        var seen = Set<String>()
        let timestamp = now()
        for row in mutation.rows {
            guard row.count <= 1 * 1_024 * 1_024,
                  DesktopWorkflowJSONSchemaValidator.validates(instance: row, against: dataset.rowSchema) else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("dataset row does not satisfy \(dataset.id)")
            }
            let values = try dataset.uniqueKeyPointers.map { pointer -> String in
                guard let value = try DesktopWorkflowStructuredValue.string(at: pointer, in: row), !value.isEmpty else {
                    throw DesktopWorkflowHostFrameworkError.invalidContract("dataset unique key is missing")
                }
                return value
            }
            let key = values.joined(separator: "\u{001f}")
            guard seen.insert(key).inserted else {
                throw DesktopWorkflowHostFrameworkError.invalidContract("dataset mutation contains duplicate keys")
            }
            proposed[key] = DesktopWorkflowDatasetRowRecord(
                id: proposed[key]?.id ?? UUID().uuidString.lowercased(), workflowID: workflowID,
                datasetID: dataset.id, scopeID: mutation.scopeID, uniqueKey: key, value: row,
                valueDigest: DesktopWorkflowStructuredValue.digest(row), revision: currentRevision + 1,
                updatedByRunID: runID, updatedAtUnixMillis: timestamp
            )
        }
        guard proposed.count <= dataset.maximumRows else {
            throw DesktopWorkflowHostFrameworkError.datasetLimitExceeded
        }
        let replacement = proposed.values.sorted { $0.uniqueKey < $1.uniqueKey }
        guard mutate({ state in
            state.operations.workflows.datasetRows.removeAll {
                $0.workflowID == workflowID && $0.datasetID == dataset.id && $0.scopeID == mutation.scopeID
            }
            state.operations.workflows.datasetRows.append(contentsOf: replacement)
            state.appendAudit(
                domain: "workflow-dataset", action: "upsert", target: "\(workflowID)/\(dataset.id)",
                state: .completed, detail: "Committed \(mutation.rows.count) row upserts at revision \(currentRevision + 1).",
                recordedAtUnixMillis: timestamp
            )
        }) else { throw DesktopWorkflowHostFrameworkError.datasetConflict }
        return currentRevision + 1
    }

    // MARK: Validation and execution evidence

    @discardableResult
    func attachWorkflowValidatorReport(
        validationID: String,
        validatorVersion: String,
        subjectDigest: String,
        findings: [DesktopWorkflowValidationFinding]
    ) -> String? {
        guard findings.count <= 10_000,
              let validation = snapshot.operations.workflows.validations.first(where: { $0.id == validationID }),
              !validatorVersion.isEmpty, !subjectDigest.isEmpty,
              findings.allSatisfy({ !$0.id.isEmpty && !$0.summary.isEmpty && $0.evidence.utf8.count <= 8_192 }) else {
            return nil
        }
        let report = DesktopWorkflowValidatorReportRecord(
            id: UUID().uuidString.lowercased(), validationID: validationID, validatorID: validation.validatorID,
            validatorVersion: validatorVersion, subjectDigest: subjectDigest,
            findings: findings, createdAtUnixMillis: now()
        )
        guard mutate({ $0.operations.workflows.validatorReports.append(report) }) else { return nil }
        return report.id
    }

    func recordWorkflowExecutionReceipt(
        attemptID: String,
        capabilityID: String,
        outputDigest: String?,
        artifactDigests: [String],
        evidence: DesktopWorkflowCapabilityExecutionEvidence
    ) -> Bool {
        guard let attempt = snapshot.operations.workflows.stepAttempts.first(where: { $0.id == attemptID }),
              !capabilityID.isEmpty else { return false }
        let receipt = DesktopWorkflowExecutionReceiptRecord(
            id: UUID().uuidString.lowercased(), runID: attempt.runID, stepAttemptID: attemptID,
            capabilityID: capabilityID, inputDigest: attempt.inputDigest, outputDigest: outputDigest,
            artifactDigests: Array(Set(artifactDigests)).sorted(), standardOutput: evidence.standardOutput,
            standardError: evidence.standardError, elapsedMilliseconds: evidence.elapsedMilliseconds,
            createdAtUnixMillis: now()
        )
        return mutate { state in
            state.operations.workflows.executionReceipts.removeAll { $0.stepAttemptID == attemptID }
            state.operations.workflows.executionReceipts.append(receipt)
        }
    }

    // MARK: Authority and effect previews

    @discardableResult
    func createWorkflowAuthorityGrant(
        workflowID: String,
        connectorID: String,
        effectKind: String,
        accountIDs: [String],
        targetPredicates: [DesktopWorkflowPredicate],
        requiresManualRun: Bool,
        maximumItemsPerExecution: Int,
        postcondition: String,
        expiresAtUnixMillis: Int64?
    ) -> String? {
        let timestamp = now()
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == workflowID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == definition.currentRevisionID }),
              revision.permissions.permissions.contains(.externalEffects),
              !connectorID.isEmpty, !effectKind.isEmpty, !accountIDs.isEmpty,
              accountIDs.count <= 128,
              accountIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }),
              !targetPredicates.isEmpty, targetPredicates.count <= 32,
              targetPredicates.allSatisfy({ $0.pointer.isEmpty || $0.pointer.hasPrefix("/") }),
              (1...10_000).contains(maximumItemsPerExecution), !postcondition.isEmpty,
              expiresAtUnixMillis.map({ $0 > timestamp }) ?? true else { return nil }
        let grant = DesktopWorkflowAuthorityGrantRecord(
            id: UUID().uuidString.lowercased(), workflowID: workflowID, connectorID: connectorID,
            effectKind: effectKind, accountIDs: Array(Set(accountIDs)).sorted(), targetPredicates: targetPredicates,
            requiresManualRun: requiresManualRun, maximumItemsPerExecution: maximumItemsPerExecution,
            postcondition: postcondition, state: .active, createdAtUnixMillis: timestamp,
            expiresAtUnixMillis: expiresAtUnixMillis, lastUsedAtUnixMillis: nil, useCount: 0
        )
        guard mutate({ state in
            state.appendWorkflowHostRecord(grant, to: \.authorityGrants)
            state.appendAudit(
                domain: "workflow-authority", action: "grant", target: grant.id, state: .approved,
                detail: "Granted bounded \(effectKind) authority for \(accountIDs.count) account scope(s).",
                recordedAtUnixMillis: timestamp
            )
        }) else { return nil }
        return grant.id
    }

    func setWorkflowAuthorityGrantState(id: String, state requested: DesktopWorkflowAuthorityGrantState) -> Bool {
        guard let current = snapshot.operations.workflows.authorityGrants.first(where: { $0.id == id }),
              current.state != .revoked, requested != .expired,
              current.state != requested else { return false }
        return mutateRecord(at: \.operations.workflows.authorityGrants, id: id) { grant in
            grant.state = requested
        }
    }

    func matchingWorkflowAuthorityGrant(
        request: DesktopWorkflowEffectRequest,
        structuredTarget: Data
    ) -> DesktopWorkflowAuthorityGrantRecord? {
        let timestamp = now()
        return snapshot.operations.workflows.authorityGrants.first { grant in
            grant.workflowID == request.workflowID && grant.connectorID == request.connectorID
                && grant.effectKind == request.effectKind && grant.state == .active
                && (grant.expiresAtUnixMillis == nil || grant.expiresAtUnixMillis! > timestamp)
                && request.accountID.map(grant.accountIDs.contains) == true
                && (!grant.requiresManualRun || request.manuallyInitiated)
                && request.itemCount <= grant.maximumItemsPerExecution
                && DesktopWorkflowStructuredValue.matches(grant.targetPredicates, data: structuredTarget)
        }
    }

    func recordWorkflowEffectPreview(
        effectID: String,
        request: DesktopWorkflowEffectRequest,
        preview: DesktopWorkflowEffectPreview
    ) -> Bool {
        guard snapshot.operations.workflows.effects.contains(where: { $0.id == effectID && $0.state == .proposed }),
              request.connectorID.utf8.count <= 128, preview.itemCount == request.itemCount,
              preview.structuredTarget.count <= 1 * 1_024 * 1_024 else { return false }
        let grant = matchingWorkflowAuthorityGrant(request: request, structuredTarget: preview.structuredTarget)
        let record = DesktopWorkflowEffectPreviewRecord(
            id: UUID().uuidString.lowercased(), effectID: effectID, request: request,
            connectorID: request.connectorID, title: preview.title, summary: preview.summary,
            structuredTarget: preview.structuredTarget,
            structuredTargetDigest: DesktopWorkflowStructuredValue.digest(preview.structuredTarget),
            itemCount: preview.itemCount, consequences: Array(preview.consequences.prefix(64)),
            reversible: preview.reversible, authorityGrantID: grant?.id, createdAtUnixMillis: now()
        )
        return mutate { state in
            state.operations.workflows.effectPreviews.removeAll { $0.effectID == effectID }
            state.operations.workflows.effectPreviews.append(record)
        }
    }

    func beginWorkflowEffectUsingAuthority(effectID: String, grantID: String) -> Bool {
        guard let effect = snapshot.operations.workflows.effects.first(where: { $0.id == effectID && $0.state == .proposed }),
              let preview = snapshot.operations.workflows.effectPreviews.first(where: {
                  $0.effectID == effectID && $0.authorityGrantID == grantID
              }), let grant = matchingWorkflowAuthorityGrant(
                  request: preview.request, structuredTarget: preview.structuredTarget
              ), grant.id == grantID else { return false }
        let timestamp = now()
        return mutate { state in
            guard let effectIndex = state.operations.workflows.effects.firstIndex(where: { $0.id == effect.id }),
                  let grantIndex = state.operations.workflows.authorityGrants.firstIndex(where: { $0.id == grantID }) else { return }
            state.operations.workflows.effects[effectIndex].state = .executing
            state.operations.workflows.authorityGrants[grantIndex].lastUsedAtUnixMillis = timestamp
            state.operations.workflows.authorityGrants[grantIndex].useCount += 1
            state.appendAudit(
                domain: "workflow-authority", action: "use", target: grantID, state: .approved,
                detail: "Authorized effect \(effect.id) under its exact bounded grant.", recordedAtUnixMillis: timestamp
            )
        }
    }

    func reconcileUnknownWorkflowEffect(
        effectID: String,
        receipt: String?,
        outcomeKnown: Bool,
        succeeded: Bool
    ) -> Bool {
        guard let effect = snapshot.operations.workflows.effects.first(where: {
            $0.id == effectID && $0.state == .outcomeUnknown
        }) else { return false }
        let timestamp = now()
        let nextState: DesktopWorkflowEffectState = !outcomeKnown ? .outcomeUnknown : (succeeded ? .reconciled : .failed)
        return mutate { state in
            guard let index = state.operations.workflows.effects.firstIndex(where: { $0.id == effectID }) else { return }
            state.operations.workflows.effects[index].state = nextState
            state.operations.workflows.effects[index].remoteReceipt = receipt
            state.operations.workflows.effects[index].reconciledAtUnixMillis = outcomeKnown ? timestamp : nil
            state.setWorkflowWorkItemPresentation(
                id: effect.workItemID,
                state: !outcomeKnown || !succeeded ? .needsAttention : .waitingExternal,
                nextAction: !outcomeKnown ? "Reconciliation remains inconclusive."
                    : (succeeded ? "The connector verified the external effect." : "The connector verified that the effect failed."),
                updatedAtUnixMillis: timestamp
            )
            state.appendAudit(
                domain: "workflow-effect", action: "reconcile", target: effect.exactTarget,
                state: !outcomeKnown ? .running : (succeeded ? .reconciled : .failed),
                detail: receipt ?? "No connector receipt was returned.", recordedAtUnixMillis: timestamp
            )
        }
    }
}

@MainActor
public final class DesktopWorkflowEffectCoordinator {
    private let model: DesktopAppModel
    private var connectors: [String: any DesktopWorkflowConnector] = [:]

    public init(model: DesktopAppModel) {
        self.model = model
    }

    public func register(_ connector: any DesktopWorkflowConnector) {
        connectors[connector.identifier] = connector
    }

    public func unregister(identifier: String) {
        connectors.removeValue(forKey: identifier)
    }

    @discardableResult
    public func preview(_ request: DesktopWorkflowEffectRequest) async throws -> String {
        guard let connector = connectors[request.connectorID] else {
            throw DesktopWorkflowHostFrameworkError.connectorUnavailable
        }
        let preview = try await connector.preview(request)
        guard preview.itemCount == request.itemCount, preview.itemCount > 0,
              !preview.exactTarget.isEmpty, !preview.title.isEmpty else {
            throw DesktopWorkflowHostFrameworkError.effectUnavailable
        }
        guard let effectID = model.proposeWorkflowEffect(
            workItemID: request.workItemID, episodeID: request.episodeID, runID: request.runID,
            stepID: request.stepID, kind: request.effectKind, accountID: request.accountID,
            exactTarget: preview.exactTarget, contentDigest: DesktopWorkflowStructuredValue.digest(request.payload),
            attachmentDigests: request.artifactDigests
        ), model.recordWorkflowEffectPreview(effectID: effectID, request: request, preview: preview) else {
            throw DesktopWorkflowHostFrameworkError.effectUnavailable
        }
        return effectID
    }

    public func execute(effectID: String) async throws -> DesktopWorkflowConnectorExecutionReceipt {
        guard let effect = model.snapshot.operations.workflows.effects.first(where: { $0.id == effectID }),
              let previewRecord = model.snapshot.operations.workflows.effectPreviews.first(where: { $0.effectID == effectID }),
              let connector = connectors[previewRecord.connectorID] else {
            throw DesktopWorkflowHostFrameworkError.effectUnavailable
        }
        let began: Bool
        if let grantID = previewRecord.authorityGrantID {
            began = model.beginWorkflowEffectUsingAuthority(effectID: effectID, grantID: grantID)
        } else {
            began = model.beginWorkflowEffect(effectID: effectID)
        }
        guard began else { throw DesktopWorkflowHostFrameworkError.authorityUnavailable }
        let preview = Self.connectorPreview(effect: effect, record: previewRecord)
        do {
            let receipt = try await connector.execute(
                previewRecord.request, preview: preview, idempotencyKey: effect.idempotencyKey
            )
            _ = model.reconcileWorkflowEffect(
                effectID: effectID, receipt: receipt.remoteReceipt ?? receipt.detail,
                outcomeKnown: receipt.outcomeKnown, succeeded: receipt.succeeded
            )
            return receipt
        } catch {
            _ = model.reconcileWorkflowEffect(effectID: effectID, receipt: nil, outcomeKnown: false, succeeded: false)
            throw error
        }
    }

    public func reconcile(effectID: String) async throws -> DesktopWorkflowConnectorExecutionReceipt {
        guard let effect = model.snapshot.operations.workflows.effects.first(where: {
            $0.id == effectID && $0.state == .outcomeUnknown
        }), let previewRecord = model.snapshot.operations.workflows.effectPreviews.first(where: { $0.effectID == effectID }),
              let connector = connectors[previewRecord.connectorID] else {
            throw DesktopWorkflowHostFrameworkError.effectUnavailable
        }
        let preview = Self.connectorPreview(effect: effect, record: previewRecord)
        let receipt = try await connector.reconcile(
            previewRecord.request, preview: preview, idempotencyKey: effect.idempotencyKey, priorReceipt: nil
        )
        // Reconciliation from an unknown state is deliberately a separate mutation path.
        guard model.reconcileUnknownWorkflowEffect(
            effectID: effectID, receipt: receipt.remoteReceipt ?? receipt.detail,
            outcomeKnown: receipt.outcomeKnown, succeeded: receipt.succeeded
        ) else { throw DesktopWorkflowHostFrameworkError.effectUnavailable }
        return receipt
    }

    private static func connectorPreview(
        effect: DesktopWorkflowEffectRecord,
        record: DesktopWorkflowEffectPreviewRecord
    ) -> DesktopWorkflowEffectPreview {
        DesktopWorkflowEffectPreview(
            title: record.title, summary: record.summary, exactTarget: effect.exactTarget,
            structuredTarget: record.structuredTarget, itemCount: record.itemCount,
            consequences: record.consequences, reversible: record.reversible
        )
    }
}

private extension DesktopAppSnapshot {
    mutating func appendWorkflowHostRecord<Record>(
        _ record: Record,
        to keyPath: WritableKeyPath<DesktopWorkflowPlatformState, [Record]>
    ) {
        operations.workflows[keyPath: keyPath].append(record)
    }
}
