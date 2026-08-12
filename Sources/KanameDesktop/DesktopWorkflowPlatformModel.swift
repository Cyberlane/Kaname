import Foundation

private func workflowPresentationOrder(
    _ left: (enabled: Bool, name: String, id: String),
    _ right: (enabled: Bool, name: String, id: String)
) -> Bool {
    if left.enabled != right.enabled { return left.enabled && !right.enabled }
    let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
    return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
}

enum WorkflowHostStepTransition {
    case wait(reason: String)
    case complete(outputDigest: String, artifactIDs: [String])
}

extension DesktopAppSnapshot {
    mutating func applyWorkflowHostStepTransition(
        attemptID: String,
        runID: String,
        workItemID: String,
        stepID: String,
        transition: WorkflowHostStepTransition,
        timestamp: Int64
    ) {
        guard let attemptIndex = operations.workflows.stepAttempts.firstIndex(where: { $0.id == attemptID }),
              let runIndex = operations.workflows.runs.firstIndex(where: { $0.id == runID }) else { return }
        switch transition {
        case let .wait(reason):
            operations.workflows.stepAttempts[attemptIndex].state = .waiting
            operations.workflows.stepAttempts[attemptIndex].errorSummary = String(reason.prefix(8_192))
            operations.workflows.stepAttempts[attemptIndex].completedAtUnixMillis = timestamp
            operations.workflows.runs[runIndex].state = .waiting
            operations.workflows.runs[runIndex].currentStepID = stepID
            setWorkflowWorkItemPresentation(
                id: workItemID,
                state: .needsAttention,
                nextAction: String(reason.prefix(8_192)),
                updatedAtUnixMillis: timestamp
            )
        case let .complete(outputDigest, artifactIDs):
            operations.workflows.stepAttempts[attemptIndex].state = .completed
            operations.workflows.stepAttempts[attemptIndex].outputDigest = outputDigest
            operations.workflows.stepAttempts[attemptIndex].artifactIDs = Array(Set(artifactIDs)).sorted()
            operations.workflows.stepAttempts[attemptIndex].errorSummary = nil
            operations.workflows.stepAttempts[attemptIndex].completedAtUnixMillis = timestamp
            operations.workflows.runs[runIndex].state = .queued
            operations.workflows.runs[runIndex].currentStepID = nil
        }
    }
}

public extension DesktopAppModel {
    func workflowRevision(runID: String) -> DesktopWorkflowRevisionRecord? {
        guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID }) else { return nil }
        return snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID })
    }

    var workflowDefinitions: [DesktopWorkflowDefinitionRecord] {
        snapshot.operations.workflows.definitions.sorted {
            workflowPresentationOrder(($0.enabled, $0.name, $0.id), ($1.enabled, $1.name, $1.id))
        }
    }

    var workflowWorkItems: [DesktopWorkflowWorkItemRecord] {
        snapshot.operations.workflows.workItems.sorted {
            ($0.updatedAtUnixMillis, $0.id) > ($1.updatedAtUnixMillis, $1.id)
        }
    }

    func workflowTriggerBindings(workflowID: String? = nil) -> [DesktopWorkflowTriggerBindingRecord] {
        snapshot.operations.workflows.triggerBindings
            .filter { workflowID == nil || $0.workflowID == workflowID }
            .sorted { ($0.updatedAtUnixMillis, $0.id) > ($1.updatedAtUnixMillis, $1.id) }
    }

    @discardableResult
    func bindWorkflowTrigger(
        workflowID: String,
        trigger: DesktopWorkflowTriggerKind,
        source: String,
        accountIDs: [String],
        sourceFilter: String,
        enabled: Bool = false
    ) -> String? {
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFilter = sourceFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedAccounts = Array(Set(accountIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }.sorted()
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == workflowID }),
              definition.triggerKinds.contains(trigger),
              !cleanSource.isEmpty, cleanSource.utf8.count <= 160,
              !cleanFilter.isEmpty, cleanFilter.utf8.count <= 2_048,
              !scopedAccounts.isEmpty,
              trigger != .email || scopedAccounts.count == 1 else { return nil }
        let timestamp = now()
        let binding = DesktopWorkflowTriggerBindingRecord(
            id: UUID().uuidString.lowercased(), workflowID: workflowID, trigger: trigger,
            source: cleanSource, accountIDs: scopedAccounts, sourceFilter: cleanFilter,
            enabled: enabled && definition.enabled, lastCursor: nil,
            createdAtUnixMillis: timestamp, updatedAtUnixMillis: timestamp
        )
        guard mutate({ state in
            state.operations.workflows.triggerBindings.append(binding)
            state.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(), domain: "workflow-trigger", action: "bound",
                target: binding.id, state: binding.enabled ? .approved : .proposed,
                detail: "Scoped \(trigger.rawValue) trigger for \(workflowID) to \(scopedAccounts.count) account(s).",
                recordedAtUnixMillis: timestamp
            ))
        }) else { return nil }
        return binding.id
    }

    func setWorkflowTriggerBindingEnabled(id: String, enabled: Bool) -> Bool {
        guard let binding = snapshot.operations.workflows.triggerBindings.first(where: { $0.id == id }),
              let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == binding.workflowID }),
              !enabled || definition.enabled else { return false }
        let timestamp = now()
        return mutateRecord(at: \.operations.workflows.triggerBindings, id: id) { binding in
            binding.enabled = enabled
            binding.updatedAtUnixMillis = timestamp
        }
    }

    func advanceWorkflowTriggerCursor(id: String, cursor: String) -> Bool {
        let cleanCursor = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCursor.isEmpty, cleanCursor.utf8.count <= 2_048 else { return false }
        let timestamp = now()
        return mutateRecord(at: \.operations.workflows.triggerBindings, id: id) { binding in
            binding.lastCursor = cleanCursor
            binding.updatedAtUnixMillis = timestamp
        }
    }

    func workflowWorkItems(accountID: String, conversationID: String) -> [DesktopWorkflowWorkItemRecord] {
        let ids = Set(snapshot.operations.workflows.conversationBindings.compactMap { binding in
            binding.accountID == accountID && binding.conversationID == conversationID
                && binding.relationship != .detached ? binding.workItemID : nil
        })
        return workflowWorkItems.filter { ids.contains($0.id) }
    }

    func workflowEpisodes(workItemID: String) -> [DesktopWorkflowEpisodeRecord] {
        snapshot.operations.workflows.episodes.filter { $0.workItemID == workItemID }
            .sorted { ($0.ordinal, $0.createdAtUnixMillis, $0.id) < ($1.ordinal, $1.createdAtUnixMillis, $1.id) }
    }

    func workflowRuns(episodeID: String) -> [DesktopWorkflowRunRecord] {
        snapshot.operations.workflows.runs.filter { $0.episodeID == episodeID }
            .sorted { (($0.startedAtUnixMillis ?? Int64.min), $0.id) < (($1.startedAtUnixMillis ?? Int64.min), $1.id) }
    }

    func workflowValidations(episodeID: String) -> [DesktopWorkflowValidationRecord] {
        snapshot.operations.workflows.validations.filter { $0.episodeID == episodeID }
            .sorted { ($0.createdAtUnixMillis, $0.id) < ($1.createdAtUnixMillis, $1.id) }
    }

    func workflowFacts(workItemID: String, includeInactive: Bool = false) -> [DesktopWorkflowFactRecord] {
        snapshot.operations.workflows.facts.filter {
            $0.workItemID == workItemID && (includeInactive || $0.state == .proposed || $0.state == .verified)
        }.sorted { ($0.key, $0.createdAtUnixMillis, $0.id) < ($1.key, $1.createdAtUnixMillis, $1.id) }
    }

    @discardableResult
    func installWorkflowPackage(
        manifestData: Data,
        registeredCapabilityIDs: Set<String>,
        enable: Bool = false
    ) throws -> String {
        let manifest = try DesktopWorkflowPackageCodec.decode(
            manifestData,
            registeredCapabilityIDs: registeredCapabilityIDs
        )
        let canonical = try DesktopWorkflowPackageCodec.canonicalData(manifest)
        let digest = DesktopWorkflowPackageCodec.digest(canonical)
        let revisionID = "\(manifest.id)@\(manifest.version)#\(digest.prefix(16))"
        if snapshot.operations.workflows.revisions.contains(where: { $0.id == revisionID }) {
            return revisionID
        }
        let timestamp = now()
        if let priorDefinition = snapshot.operations.workflows.definitions.first(where: { $0.id == manifest.id }),
           let priorRevision = snapshot.operations.workflows.revisions.first(where: { $0.id == priorDefinition.currentRevisionID }),
           manifest.permissions.broadens(priorRevision.permissions), enable {
            throw DesktopWorkflowPackageError.permissionBroadening
        }
        let revision = DesktopWorkflowRevisionRecord(
            id: revisionID, workflowID: manifest.id, version: manifest.version,
            schemaVersion: manifest.schemaVersion, manifestDigest: digest, steps: manifest.steps,
            permissions: manifest.permissions, correlationSummary: manifest.correlationSummary,
            contextSummary: manifest.contextSummary, completionSummary: manifest.completionSummary,
            datasetDefinitions: manifest.datasets,
            installedAtUnixMillis: timestamp
        )
        let definition = DesktopWorkflowDefinitionRecord(
            id: manifest.id, name: manifest.name, summary: manifest.summary, icon: manifest.icon,
            source: manifest.source, license: manifest.license, currentRevisionID: revision.id,
            enabled: enable, triggerKinds: Array(Set(manifest.triggers)).sorted { $0.rawValue < $1.rawValue },
            createdAtUnixMillis: snapshot.operations.workflows.definitions.first(where: { $0.id == manifest.id })?.createdAtUnixMillis ?? timestamp,
            updatedAtUnixMillis: timestamp
        )
        guard mutate({ state in
            state.operations.workflows.revisions.append(revision)
            if let index = state.operations.workflows.definitions.firstIndex(where: { $0.id == definition.id }) {
                state.operations.workflows.definitions[index] = definition
            } else {
                state.operations.workflows.definitions.append(definition)
            }
            state.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(), domain: "workflow-package", action: "installed",
                target: "\(definition.id)@\(revision.version)", state: enable ? .approved : .proposed,
                detail: enable
                    ? "Installed and enabled an exact reviewed workflow revision."
                    : "Installed disabled. Review its permissions before enabling.",
                recordedAtUnixMillis: timestamp
            ))
        }) else { throw DesktopWorkflowPackageError.invalidSchema }
        return revision.id
    }

    func setWorkflowEnabled(id: String, enabled: Bool) -> Bool {
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == id }),
              snapshot.operations.workflows.revisions.contains(where: { $0.id == definition.currentRevisionID }) else {
            return false
        }
        let timestamp = now()
        return mutate { state in
            guard let index = state.operations.workflows.definitions.firstIndex(where: { $0.id == id }) else { return }
            state.operations.workflows.definitions[index].enabled = enabled
            state.operations.workflows.definitions[index].updatedAtUnixMillis = timestamp
            if !enabled {
                for bindingIndex in state.operations.workflows.triggerBindings.indices
                    where state.operations.workflows.triggerBindings[bindingIndex].workflowID == id {
                    state.operations.workflows.triggerBindings[bindingIndex].enabled = false
                    state.operations.workflows.triggerBindings[bindingIndex].updatedAtUnixMillis = timestamp
                }
            }
            state.operations.audit.append(DesktopAuditRecord(
                id: UUID().uuidString.lowercased(), domain: "workflow-package",
                action: enabled ? "enabled" : "disabled", target: id,
                state: enabled ? .approved : .cancelled,
                detail: enabled ? "Enabled the exact installed workflow revision." : "Disabled future workflow dispatch.",
                recordedAtUnixMillis: timestamp
            ))
        }
    }

    @discardableResult
    func createWorkflowWorkItem(workflowID: String, title: String, goal: String) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == workflowID && $0.enabled }),
              snapshot.operations.workflows.revisions.contains(where: { $0.id == definition.currentRevisionID }),
              !cleanTitle.isEmpty, cleanTitle.utf8.count <= 240,
              !cleanGoal.isEmpty, cleanGoal.utf8.count <= 8_192 else { return nil }
        let timestamp = now()
        let item = DesktopWorkflowWorkItemRecord(
            id: UUID().uuidString.lowercased(), workflowID: workflowID, title: cleanTitle, goal: cleanGoal,
            state: .open, currentEpisodeID: nil, nextAction: "Wait for or attach a triggering event.",
            explicitAcceptance: false, createdAtUnixMillis: timestamp, updatedAtUnixMillis: timestamp, closedAtUnixMillis: nil
        )
        guard mutate({ state in
            state.operations.workflows.workItems.append(item)
            state.appendAudit(
                domain: "workflow", action: "work-item-created", target: item.id,
                state: .completed, detail: item.title, recordedAtUnixMillis: timestamp
            )
        }) else { return nil }
        return item.id
    }

    @discardableResult
    func observeWorkflowExternalEvent(
        source: String,
        accountID: String,
        conversationID: String?,
        messageID: String?,
        cursor: String?,
        payloadDigest: String,
        deduplicationKey: String
    ) -> String? {
        let normalized = [source, accountID, payloadDigest, deduplicationKey]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }) else { return nil }
        if let existing = snapshot.operations.workflows.externalEvents.first(where: {
            $0.source == normalized[0] && $0.accountID == normalized[1] && $0.deduplicationKey == normalized[3]
        }) { return existing.id }
        let event = DesktopWorkflowExternalEventRecord(
            id: UUID().uuidString.lowercased(), source: normalized[0], accountID: normalized[1],
            conversationID: conversationID, messageID: messageID, cursor: cursor,
            payloadDigest: normalized[2], deduplicationKey: normalized[3], observedAtUnixMillis: now()
        )
        return mutate({ $0.operations.workflows.externalEvents.append(event) }) ? event.id : nil
    }

    @discardableResult
    func bindWorkflowConversation(
        workItemID: String,
        source: String,
        accountID: String,
        conversationID: String,
        relationship: DesktopWorkflowConversationRelationship,
        reason: String,
        confidence: Double,
        requiresReview: Bool,
        firstMessageID: String? = nil,
        latestMessageID: String? = nil
    ) -> String? {
        guard snapshot.operations.workflows.workItems.contains(where: { $0.id == workItemID }),
              !source.isEmpty, !accountID.isEmpty, !conversationID.isEmpty,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (0...1).contains(confidence) else { return nil }
        if let existing = snapshot.operations.workflows.conversationBindings.first(where: {
            $0.workItemID == workItemID && $0.source == source && $0.accountID == accountID
                && $0.conversationID == conversationID && $0.relationship != .detached
        }) { return existing.id }
        let timestamp = now()
        let binding = DesktopWorkflowConversationBindingRecord(
            id: UUID().uuidString.lowercased(), workItemID: workItemID, source: source, accountID: accountID,
            conversationID: conversationID, relationship: relationship, correlationReason: reason,
            confidence: confidence, requiresReview: requiresReview, firstMessageID: firstMessageID,
            latestMessageID: latestMessageID, createdAtUnixMillis: timestamp
        )
        guard mutate({ state in
            if requiresReview {
                state.appendWorkflowRecord(
                    binding, at: \.operations.workflows.conversationBindings,
                    workItemID: workItemID, workState: .needsAttention,
                    nextAction: "Review the proposed conversation association.",
                    updatedAtUnixMillis: timestamp
                )
            } else {
                state.operations.workflows.conversationBindings.append(binding)
            }
        }) else { return nil }
        return binding.id
    }

    func reviewWorkflowConversationBinding(id: String, accepted: Bool) -> Bool {
        guard let binding = snapshot.operations.workflows.conversationBindings.first(where: { $0.id == id }) else {
            return false
        }
        let timestamp = now()
        return mutate { state in
            _ = state.changeTwoRecords(
                first: \.operations.workflows.conversationBindings, id: id,
                change: { storedBinding in
                    storedBinding.requiresReview = false
                    if !accepted { storedBinding.relationship = .detached }
                },
                second: \.operations.workflows.workItems, id: binding.workItemID,
                change: { item in
                    item.state = .open
                    item.nextAction = accepted
                        ? "Create an episode from the associated event."
                        : "Choose or create the correct work item."
                    item.updatedAtUnixMillis = timestamp
                }
            )
        }
    }

    @discardableResult
    func createWorkflowEpisode(
        workItemID: String,
        sourceEventID: String,
        sourceMessageID: String?,
        intent: DesktopWorkflowEpisodeIntent,
        summary: String,
        deltaSummary: String
    ) -> String? {
        guard let item = snapshot.operations.workflows.workItems.first(where: { $0.id == workItemID }),
              let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == item.workflowID && $0.enabled }),
              snapshot.operations.workflows.externalEvents.contains(where: { $0.id == sourceEventID }),
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let existing = snapshot.operations.workflows.episodes.first(where: {
            $0.workItemID == workItemID && $0.sourceEventID == sourceEventID
        }) { return existing.id }
        let priorEpisodes = workflowEpisodes(workItemID: workItemID)
        let timestamp = now()
        let episode = DesktopWorkflowEpisodeRecord(
            id: UUID().uuidString.lowercased(), workItemID: workItemID, ordinal: (priorEpisodes.last?.ordinal ?? 0) + 1,
            intent: intent, sourceEventID: sourceEventID, sourceMessageID: sourceMessageID,
            summary: String(summary.prefix(8_192)), deltaSummary: String(deltaSummary.prefix(8_192)),
            state: .preparing, workflowRevisionID: definition.currentRevisionID,
            supersedesEpisodeID: intent == .correction ? priorEpisodes.last?.id : nil,
            createdAtUnixMillis: timestamp
        )
        guard mutate({ state in
            if let priorID = episode.supersedesEpisodeID,
               state.changeRecord(at: \.operations.workflows.episodes, id: priorID, change: { $0.state = .superseded }) {
            }
            state.operations.workflows.episodes.append(episode)
            state.changeRecord(at: \.operations.workflows.workItems, id: workItemID) { item in
                item.currentEpisodeID = episode.id
                item.state = .preparing
                item.nextAction = "Review interpretation and compile current context."
                item.updatedAtUnixMillis = timestamp
            }
        }) else { return nil }
        return episode.id
    }

    @discardableResult
    func recordWorkflowFact(
        workItemID: String,
        episodeID: String,
        key: String,
        value: String,
        state factState: DesktopWorkflowFactState,
        sourceReferenceIDs: [String],
        verifiedBy: String? = nil,
        supersedesFactID: String? = nil
    ) -> String? {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.operations.workflows.workItems.contains(where: { $0.id == workItemID }),
              snapshot.operations.workflows.episodes.contains(where: { $0.id == episodeID && $0.workItemID == workItemID }),
              !cleanKey.isEmpty, cleanKey.utf8.count <= 240, !cleanValue.isEmpty, cleanValue.utf8.count <= 8_192,
              supersedesFactID == nil || snapshot.operations.workflows.facts.contains(where: { $0.id == supersedesFactID && $0.workItemID == workItemID }) else {
            return nil
        }
        let fact = DesktopWorkflowFactRecord(
            id: UUID().uuidString.lowercased(), workItemID: workItemID, key: cleanKey, value: cleanValue,
            state: factState, sourceReferenceIDs: Array(Set(sourceReferenceIDs)).sorted(), verifiedBy: verifiedBy,
            episodeID: episodeID, supersededByFactID: nil, createdAtUnixMillis: now(),
            scope: .workItem,
            workflowID: snapshot.operations.workflows.workItems.first(where: { $0.id == workItemID })?.workflowID,
            proposedSupersedesFactID: factState == .proposed ? supersedesFactID : nil,
            scopeID: workItemID
        )
        guard mutate({ state in
            if factState != .proposed, let oldID = supersedesFactID {
                state.changeRecord(at: \.operations.workflows.facts, id: oldID) { oldFact in
                    oldFact.state = .superseded
                    oldFact.supersededByFactID = fact.id
                }
            }
            state.operations.workflows.facts.append(fact)
        }) else { return nil }
        return fact.id
    }

    @discardableResult
    func compileWorkflowContext(
        workItemID: String,
        episodeID: String,
        request: String,
        references: [DesktopWorkflowContextReference],
        openQuestions: [String] = [],
        negativeConstraints: [String] = [],
        tokenBudget: Int = 32_000
    ) -> String? {
        guard let item = snapshot.operations.workflows.workItems.first(where: { $0.id == workItemID }),
              let episode = snapshot.operations.workflows.episodes.first(where: { $0.id == episodeID && $0.workItemID == workItemID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == episode.workflowRevisionID }),
              let context = DesktopWorkflowContextCompiler.compile(
                workItem: item, episode: episode, facts: snapshot.operations.workflows.facts,
                references: references, request: request, openQuestions: openQuestions,
                negativeConstraints: negativeConstraints, authority: revision.permissions,
                accountIDs: Set(snapshot.operations.workflows.conversationBindings.filter {
                    $0.workItemID == workItemID && $0.relationship != .detached
                }.map(\.accountID)),
                createdAtUnixMillis: now(), tokenBudget: tokenBudget
              ) else { return nil }
        guard mutate({ state in
            state.appendWorkflowRecord(
                context, at: \.operations.workflows.contextSnapshots,
                workItemID: workItemID,
                nextAction: "Run the exact workflow revision with this frozen context.",
                updatedAtUnixMillis: context.createdAtUnixMillis
            )
        }) else { return nil }
        return context.id
    }

    @discardableResult
    func queueWorkflowRun(
        workItemID: String,
        episodeID: String,
        contextSnapshotID: String,
        retryMode: DesktopWorkflowRetryMode = .initial,
        priorRunID: String? = nil
    ) -> String? {
        guard let episode = snapshot.operations.workflows.episodes.first(where: { $0.id == episodeID && $0.workItemID == workItemID }),
              snapshot.operations.workflows.contextSnapshots.contains(where: {
                  $0.id == contextSnapshotID && $0.workItemID == workItemID && $0.episodeID == episodeID
              }), retryMode == .initial || priorRunID != nil else { return nil }
        let run = DesktopWorkflowRunRecord(
            id: UUID().uuidString.lowercased(), workItemID: workItemID, episodeID: episodeID,
            workflowRevisionID: retryMode == .currentRevision
                ? snapshot.operations.workflows.definitions.first(where: { $0.id == snapshot.operations.workflows.workItems.first(where: { $0.id == workItemID })?.workflowID })?.currentRevisionID ?? episode.workflowRevisionID
                : episode.workflowRevisionID,
            retryMode: retryMode, priorRunID: priorRunID, contextSnapshotID: contextSnapshotID,
            state: .queued, currentStepID: nil, traceID: UUID().uuidString.lowercased(),
            startedAtUnixMillis: nil, completedAtUnixMillis: nil
        )
        guard mutate({ state in
            state.appendWorkflowRecord(
                run, at: \.operations.workflows.runs, workItemID: workItemID,
                workState: .preparing, nextAction: "Workflow run queued.",
                updatedAtUnixMillis: self.now()
            )
        }) else { return nil }
        return run.id
    }

    /// Returns the next ordered stage only when no stage is currently running
    /// and every prior blocking stage has completed. Capability executors use
    /// this as the durable dispatch contract rather than maintaining a private
    /// in-memory cursor.
    func nextWorkflowStep(runID: String) -> DesktopWorkflowStepDefinition? {
        guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID }),
              run.state == .queued || run.state == .running,
              run.currentStepID == nil,
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }) else {
            return nil
        }
        let attempts = snapshot.operations.workflows.stepAttempts.filter { $0.runID == runID }
        if revision.schemaVersion >= 2 {
            var stepID = revision.steps.first?.id
            var visited = Set<String>()
            while let currentID = stepID, visited.insert(currentID).inserted,
                  let step = revision.steps.first(where: { $0.id == currentID }) {
                let stepAttempts = attempts.filter { $0.stepID == currentID }
                let handledFailure = snapshot.operations.workflows.transitionRecords.contains {
                    $0.runID == runID && $0.fromStepID == currentID && $0.outcome == .failed
                }
                if !stepAttempts.contains(where: { $0.state == .completed }) && !handledFailure {
                    if let latest = stepAttempts.max(by: { $0.attempt < $1.attempt }), latest.state == .failed {
                        guard step.isIdempotent, latest.attempt <= step.retryLimit else { return nil }
                    }
                    return step
                }
                guard step.kind != .complete else { return nil }
                stepID = snapshot.operations.workflows.transitionRecords
                    .filter { $0.runID == runID && $0.fromStepID == currentID }
                    .max(by: { $0.createdAtUnixMillis < $1.createdAtUnixMillis })?.toStepID
            }
            return nil
        }
        for step in revision.steps {
            let stepAttempts = attempts.filter { $0.stepID == step.id }
            if stepAttempts.contains(where: { $0.state == .completed }) { continue }
            if let latest = stepAttempts.max(by: { $0.attempt < $1.attempt }), latest.state == .failed {
                guard step.isIdempotent, latest.attempt <= step.retryLimit else { return nil }
            }
            return step
        }
        return nil
    }

    func completeWorkflowRun(id: String) -> Bool {
        guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == id && ($0.state == .queued || $0.state == .running) }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }) else {
            return false
        }
        let attempts = snapshot.operations.workflows.stepAttempts.filter { $0.runID == id }
        if revision.schemaVersion >= 2 {
            guard revision.steps.contains(where: { step in
                step.kind == .complete && attempts.contains(where: { $0.stepID == step.id && $0.state == .completed })
            }) else { return false }
        } else {
            guard revision.steps.allSatisfy({ step in
                attempts.contains(where: { $0.stepID == step.id && $0.state == .completed })
            }) else { return false }
        }
        let timestamp = now()
        return mutate { state in
            guard state.changeRecord(at: \.operations.workflows.runs, id: id, change: { storedRun in
                storedRun.state = .completed
                storedRun.currentStepID = nil
                storedRun.completedAtUnixMillis = timestamp
            }) else { return }
            let hasPendingEffect = state.operations.workflows.effects.contains {
                $0.runID == id && $0.state != .reconciled && $0.state != .cancelled
            }
            state.setWorkflowWorkItemPresentation(
                id: run.workItemID,
                state: hasPendingEffect ? .readyForEffect : .waitingExternal,
                nextAction: hasPendingEffect
                    ? "Review the exact proposed effect."
                    : "Run complete. Wait for an external reply or record acceptance.",
                updatedAtUnixMillis: timestamp
            )
        }
    }

    @discardableResult
    func beginWorkflowStep(runID: String, stepID: String, inputDigest: String) -> String? {
        guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID && ($0.state == .queued || $0.state == .running) }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
              revision.steps.contains(where: { $0.id == stepID }),
              !snapshot.operations.workflows.stepAttempts.contains(where: { $0.runID == runID && $0.stepID == stepID && $0.state == .running }),
              !inputDigest.isEmpty else { return nil }
        let timestamp = now()
        let attemptNumber = snapshot.operations.workflows.stepAttempts.filter { $0.runID == runID && $0.stepID == stepID }.count + 1
        let previous = snapshot.operations.workflows.stepAttempts.last(where: { $0.runID == runID })
        let attempt = DesktopWorkflowStepAttemptRecord(
            id: UUID().uuidString.lowercased(), runID: runID, stepID: stepID, attempt: attemptNumber,
            state: .running, inputDigest: inputDigest, outputDigest: nil, providerRunID: nil,
            artifactIDs: [], errorSummary: nil, spanID: UUID().uuidString.lowercased(),
            parentSpanID: previous?.spanID, startedAtUnixMillis: timestamp, completedAtUnixMillis: nil
        )
        guard mutate({ state in
            state.operations.workflows.stepAttempts.append(attempt)
            guard let runIndex = state.operations.workflows.runs.firstIndex(where: { $0.id == runID }) else { return }
            state.operations.workflows.runs[runIndex].state = .running
            state.operations.workflows.runs[runIndex].currentStepID = stepID
            state.operations.workflows.runs[runIndex].startedAtUnixMillis = state.operations.workflows.runs[runIndex].startedAtUnixMillis ?? timestamp
            if let itemIndex = state.operations.workflows.workItems.firstIndex(where: { $0.id == run.workItemID }) {
                state.operations.workflows.workItems[itemIndex].state = .running
                state.operations.workflows.workItems[itemIndex].nextAction = "Running \(revision.steps.first(where: { $0.id == stepID })?.name ?? stepID)."
                state.operations.workflows.workItems[itemIndex].updatedAtUnixMillis = timestamp
            }
        }) else { return nil }
        return attempt.id
    }

    func completeWorkflowStep(
        attemptID: String,
        outputDigest: String?,
        artifactIDs: [String] = [],
        providerRunID: String? = nil,
        error: String? = nil,
        commitProposal: DesktopWorkflowCapabilityCommitProposal = .init(),
        artifactMetadata: [DesktopWorkflowStoredArtifact] = []
    ) -> Bool {
        guard let attempt = snapshot.operations.workflows.stepAttempts.first(where: { $0.id == attemptID && $0.state == .running }),
              let run = snapshot.operations.workflows.runs.first(where: { $0.id == attempt.runID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
              let step = revision.steps.first(where: { $0.id == attempt.stepID }),
              let workItem = snapshot.operations.workflows.workItems.first(where: { $0.id == run.workItemID }) else { return false }
        do { try DesktopWorkflowDataPlaneValidation.validate(commitProposal) } catch { return false }
        let accountScopeIDs = Set(snapshot.operations.workflows.conversationBindings.filter {
            $0.workItemID == workItem.id && $0.relationship != .detached
        }.map(\.accountID))
        let scopeContext = DesktopWorkflowResolvedDataScope(
            workflowID: workItem.workflowID, workItemID: workItem.id,
            runID: run.id, accountIDs: accountScopeIDs
        )
        let mutationIDs = commitProposal.stateMutations.map { "\($0.scope.rawValue):\($0.namespace):\($0.key)" }
        guard Set(mutationIDs).count == mutationIDs.count,
              commitProposal.stateMutations.allSatisfy({ mutation in
                  guard let owner = scopeContext.identifier(for: mutation.scope) else { return false }
                  let current = snapshot.operations.workflows.stateRecords.first {
                      $0.matches(
                          workflowID: workItem.workflowID, scopeID: owner,
                          namespace: mutation.namespace, key: mutation.key
                      )
                  }
                  return mutation.expectedRevision == current?.revision
                      && (current == nil || mutation.schemaVersion >= current!.schemaVersion)
              }),
              commitProposal.knowledgeProposals.allSatisfy({ proposal in
                  proposal.scope != .run && scopeContext.identifier(for: proposal.scope) != nil
                      && (proposal.supersedesFactID == nil || snapshot.operations.workflows.facts.contains {
                      $0.id == proposal.supersedesFactID && $0.workflowID == workItem.workflowID
                  })
              }),
              commitProposal.artifactRoles.allSatisfy({ artifactIDs.contains($0.artifactDigest) }),
              Set(commitProposal.artifactRoles.map(\.role)).count == commitProposal.artifactRoles.count else { return false }
        var projectedState = snapshot.operations.workflows.stateRecords.filter { $0.workflowID == workItem.workflowID }
        for mutation in commitProposal.stateMutations {
            let owner = scopeContext.identifier(for: mutation.scope)!
            projectedState.removeAll {
                $0.matches(
                    workflowID: workItem.workflowID, scopeID: owner,
                    namespace: mutation.namespace, key: mutation.key
                )
            }
            if let value = mutation.value {
                projectedState.append(DesktopWorkflowStateRecord(
                    workflowID: workItem.workflowID, namespace: mutation.namespace, key: mutation.key,
                    scope: mutation.scope, scopeID: owner, schemaVersion: mutation.schemaVersion, schema: mutation.schema,
                    value: value, revision: (mutation.expectedRevision ?? 0) + 1,
                    updatedByRunID: run.id, updatedAtUnixMillis: now()
                ))
            }
        }
        guard projectedState.reduce(0, { $0 + $1.value.count }) <= DesktopWorkflowStorage.maximumValuesBytes else { return false }
        let timestamp = now()
        let failed = error != nil
        return mutate { state in
            guard let attemptIndex = state.operations.workflows.stepAttempts.firstIndex(where: { $0.id == attemptID }),
                  let runIndex = state.operations.workflows.runs.firstIndex(where: { $0.id == run.id }) else { return }
            state.operations.workflows.stepAttempts[attemptIndex].state = failed ? .failed : .completed
            state.operations.workflows.stepAttempts[attemptIndex].outputDigest = outputDigest
            state.operations.workflows.stepAttempts[attemptIndex].artifactIDs = Array(Set(artifactIDs)).sorted()
            state.operations.workflows.stepAttempts[attemptIndex].providerRunID = providerRunID
            state.operations.workflows.stepAttempts[attemptIndex].errorSummary = error.map { String($0.prefix(8_192)) }
            state.operations.workflows.stepAttempts[attemptIndex].completedAtUnixMillis = timestamp
            state.operations.workflows.runs[runIndex].currentStepID = nil
            if !failed {
                for mutation in commitProposal.stateMutations {
                    let owner = scopeContext.identifier(for: mutation.scope)!
                    state.operations.workflows.stateRecords.removeAll {
                        $0.matches(
                            workflowID: workItem.workflowID, scopeID: owner,
                            namespace: mutation.namespace, key: mutation.key
                        )
                    }
                    if let value = mutation.value {
                        state.operations.workflows.stateRecords.append(DesktopWorkflowStateRecord(
                            workflowID: workItem.workflowID, namespace: mutation.namespace, key: mutation.key,
                            scope: mutation.scope, scopeID: owner,
                            schemaVersion: mutation.schemaVersion, schema: mutation.schema,
                            value: value, revision: (mutation.expectedRevision ?? 0) + 1,
                            updatedByRunID: run.id, updatedAtUnixMillis: timestamp
                        ))
                    }
                }
                for proposal in commitProposal.knowledgeProposals {
                    let factID = UUID().uuidString.lowercased()
                    state.operations.workflows.facts.append(DesktopWorkflowFactRecord(
                        id: factID, workItemID: workItem.id, key: proposal.key, value: proposal.value,
                        state: .proposed, sourceReferenceIDs: Array(Set(proposal.sourceReferenceIDs + [run.id, run.episodeID])).sorted(),
                        verifiedBy: nil, episodeID: run.episodeID, supersededByFactID: nil,
                        createdAtUnixMillis: timestamp, scope: proposal.scope, workflowID: workItem.workflowID,
                        proposedSupersedesFactID: proposal.supersedesFactID,
                        scopeID: scopeContext.identifier(for: proposal.scope)
                    ))
                }
                for proposal in commitProposal.artifactRoles {
                    let roleID = UUID().uuidString.lowercased()
                    for index in state.operations.workflows.artifactRoles.indices
                        where state.operations.workflows.artifactRoles[index].workflowID == workItem.workflowID
                            && state.operations.workflows.artifactRoles[index].workItemID == workItem.id
                            && state.operations.workflows.artifactRoles[index].role == proposal.role
                            && state.operations.workflows.artifactRoles[index].active {
                        state.operations.workflows.artifactRoles[index].active = false
                        state.operations.workflows.artifactRoles[index].supersededByID = roleID
                    }
                    let metadata = artifactMetadata.first { $0.sha256 == proposal.artifactDigest }
                    state.operations.workflows.artifactRoles.append(DesktopWorkflowArtifactRoleRecord(
                        id: roleID, workflowID: workItem.workflowID, workItemID: workItem.id, episodeID: run.episodeID,
                        role: proposal.role, artifactDigest: proposal.artifactDigest,
                        filename: metadata?.filename ?? proposal.artifactDigest,
                        mediaType: metadata?.mediaType ?? "application/octet-stream", active: true,
                        supersededByID: nil, createdByRunID: run.id, createdAtUnixMillis: timestamp
                    ))
                }
                if !commitProposal.isEmpty {
                    state.appendAudit(
                        domain: "workflow-data", action: "capability-commit", target: attemptID,
                        state: .completed,
                        detail: "\(commitProposal.stateMutations.count) state · \(commitProposal.knowledgeProposals.count) knowledge · \(commitProposal.artifactRoles.count) artifact role",
                        recordedAtUnixMillis: timestamp
                    )
                }
            }
            if failed && step.blocking {
                state.operations.workflows.runs[runIndex].state = .failed
                state.operations.workflows.runs[runIndex].completedAtUnixMillis = timestamp
                if let itemIndex = state.operations.workflows.workItems.firstIndex(where: { $0.id == run.workItemID }) {
                    state.operations.workflows.workItems[itemIndex].state = .needsAttention
                    state.operations.workflows.workItems[itemIndex].nextAction = step.isIdempotent && attempt.attempt <= step.retryLimit
                        ? "Review the failure and retry this idempotent step."
                        : "Review the blocking failure. No automatic retry is permitted."
                    state.operations.workflows.workItems[itemIndex].updatedAtUnixMillis = timestamp
                }
            }
        }
    }

    func attachProviderRunToWorkflowStep(providerRunID: String, stepAttemptID: String) -> Bool {
        guard let attempt = snapshot.operations.workflows.stepAttempts.first(where: { $0.id == stepAttemptID }),
              let run = snapshot.operations.workflows.runs.first(where: { $0.id == attempt.runID }),
              let providerRun = snapshot.operations.providerRuns.first(where: { $0.id == providerRunID }),
              providerRun.workflowRunID == nil else { return false }
        return mutate { state in
            _ = state.attachWorkflowProviderLinkage(
                providerRunID: providerRunID, stepAttemptID: stepAttemptID,
                run: run, attempt: attempt
            )
        }
    }

    @discardableResult
    func recordWorkflowValidation(
        workItemID: String,
        episodeID: String,
        runID: String,
        validatorID: String,
        validatorRevision: String,
        targetID: String,
        severity: DesktopWorkflowValidationSeverity,
        outcome: DesktopWorkflowValidationOutcome,
        summary: String,
        evidenceArtifactIDs: [String] = []
    ) -> String? {
        guard snapshot.operations.workflows.runs.contains(where: { $0.id == runID && $0.workItemID == workItemID && $0.episodeID == episodeID }),
              !validatorID.isEmpty, !validatorRevision.isEmpty, !targetID.isEmpty, !summary.isEmpty else { return nil }
        let timestamp = now()
        let validation = DesktopWorkflowValidationRecord(
            id: UUID().uuidString.lowercased(), workItemID: workItemID, episodeID: episodeID, runID: runID,
            validatorID: validatorID, validatorRevision: validatorRevision, targetID: targetID,
            severity: severity, outcome: outcome, summary: String(summary.prefix(8_192)),
            evidenceArtifactIDs: Array(Set(evidenceArtifactIDs)).sorted(), waiverDecisionID: nil,
            createdAtUnixMillis: timestamp
        )
        guard mutate({ state in
            state.operations.workflows.validations.append(validation)
            if severity == .blocking && outcome != .passed,
               let itemIndex = state.operations.workflows.workItems.firstIndex(where: { $0.id == workItemID }) {
                state.operations.workflows.workItems[itemIndex].state = .needsAttention
                state.operations.workflows.workItems[itemIndex].nextAction = "Resolve the blocking validation: \(validation.summary)"
                state.operations.workflows.workItems[itemIndex].updatedAtUnixMillis = timestamp
            }
        }) else { return nil }
        return validation.id
    }

    @discardableResult
    func proposeWorkflowEffect(
        workItemID: String,
        episodeID: String,
        runID: String,
        stepID: String,
        kind: String,
        accountID: String?,
        exactTarget: String,
        contentDigest: String,
        attachmentDigests: [String]
    ) -> String? {
        guard let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID && $0.workItemID == workItemID && $0.episodeID == episodeID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
              revision.steps.contains(where: { $0.id == stepID && [.createEmailDraft, .sendEmail, .effect].contains($0.kind) }),
              !kind.isEmpty, !exactTarget.isEmpty, !contentDigest.isEmpty,
              !snapshot.operations.workflows.validations.contains(where: {
                  $0.runID == runID && $0.severity == .blocking && $0.outcome != .passed && $0.waiverDecisionID == nil
              }) else { return nil }
        let timestamp = now()
        let idempotency = DesktopWorkflowPackageCodec.digest(Data("\(workItemID)|\(episodeID)|\(runID)|\(stepID)|\(exactTarget)|\(contentDigest)|\(attachmentDigests.sorted().joined(separator: ","))".utf8))
        if let prior = snapshot.operations.workflows.effects.first(where: { $0.idempotencyKey == idempotency }) { return prior.id }
        let effect = DesktopWorkflowEffectRecord(
            id: UUID().uuidString.lowercased(), workItemID: workItemID, episodeID: episodeID,
            runID: runID, stepID: stepID, kind: kind, accountID: accountID, exactTarget: exactTarget,
            contentDigest: contentDigest, attachmentDigests: attachmentDigests.sorted(), approvalID: nil,
            idempotencyKey: idempotency, state: .proposed, remoteReceipt: nil,
            createdAtUnixMillis: timestamp, reconciledAtUnixMillis: nil
        )
        guard mutate({ state in
            state.appendWorkflowRecord(
                effect, at: \.operations.workflows.effects, workItemID: workItemID,
                workState: .readyForEffect,
                nextAction: "Review and approve the exact external effect.",
                updatedAtUnixMillis: timestamp
            )
        }) else { return nil }
        return effect.id
    }

    func attachWorkflowEffectApproval(effectID: String, approvalID: String) -> Bool {
        guard let effect = snapshot.operations.workflows.effects.first(where: { $0.id == effectID && $0.state == .proposed }),
              let approval = snapshot.operations.approvals.first(where: {
                  $0.id == approvalID && $0.exactTarget == effect.exactTarget && $0.state == .awaitingApproval
              }) else { return false }
        return mutateRecord(at: \.operations.workflows.effects, id: effectID) { effect in
            effect.approvalID = approval.id
            effect.state = .awaitingApproval
        }
    }

    func beginWorkflowEffect(effectID: String) -> Bool {
        guard let effect = snapshot.operations.workflows.effects.first(where: { $0.id == effectID }),
              effect.state == .approved || effect.state == .awaitingApproval,
              effect.remoteReceipt == nil, !effect.idempotencyKey.isEmpty,
              let approvalID = effect.approvalID,
              exactEffectIsAuthorized(approvalID: approvalID, target: effect.exactTarget) else { return false }
        return mutateRecord(at: \.operations.workflows.effects, id: effectID) { $0.state = .executing }
    }

    func reconcileWorkflowEffect(effectID: String, receipt: String?, outcomeKnown: Bool, succeeded: Bool) -> Bool {
        guard let effect = snapshot.operations.workflows.effects.first(where: { $0.id == effectID && $0.state == .executing }) else {
            return false
        }
        let timestamp = now()
        let newState: DesktopWorkflowEffectState = !outcomeKnown ? .outcomeUnknown : (succeeded ? .reconciled : .failed)
        let nextAction = !outcomeKnown
            ? "Reconcile the provider outcome before any retry."
            : (succeeded ? "Wait for an external reply or explicit acceptance." : "Review the failed effect before retrying.")
        return mutate { state in
            guard state.changeRecord(at: \.operations.workflows.effects, id: effectID, change: { storedEffect in
                storedEffect.state = newState
                storedEffect.remoteReceipt = receipt
                storedEffect.reconciledAtUnixMillis = outcomeKnown ? timestamp : nil
            }) else { return }
            state.setWorkflowWorkItemPresentation(
                id: effect.workItemID,
                state: !outcomeKnown || !succeeded ? .needsAttention : .waitingExternal,
                nextAction: nextAction, updatedAtUnixMillis: timestamp
            )
            state.appendAudit(
                domain: "workflow-effect", action: effect.kind, target: effect.exactTarget,
                state: !outcomeKnown ? .running : (succeeded ? .reconciled : .failed),
                detail: receipt ?? (!outcomeKnown ? "Outcome unknown; reconciliation required." : "No remote receipt was returned."),
                recordedAtUnixMillis: timestamp
            )
        }
    }

    func closeWorkflowWorkItem(id: String, accepted: Bool) -> Bool {
        let timestamp = now()
        return mutate { state in
            guard let index = state.operations.workflows.workItems.firstIndex(where: { $0.id == id }) else { return }
            state.operations.workflows.workItems[index].state = accepted ? .accepted : .operationallyClosed
            state.operations.workflows.workItems[index].explicitAcceptance = accepted
            state.operations.workflows.workItems[index].nextAction = accepted
                ? "Explicit acceptance recorded."
                : "Closed operationally without claiming external acceptance."
            state.operations.workflows.workItems[index].updatedAtUnixMillis = timestamp
            state.operations.workflows.workItems[index].closedAtUnixMillis = timestamp
        }
    }

    var workflowCapabilityInstallations: [DesktopWorkflowCapabilityInstallationRecord] {
        snapshot.operations.workflows.capabilityInstallations.sorted {
            workflowPresentationOrder(($0.enabled, $0.name, $0.id), ($1.enabled, $1.name, $1.id))
        }
    }

    func workflowCapabilityInstallation(capabilityID: String) -> DesktopWorkflowCapabilityInstallationRecord? {
        snapshot.operations.workflows.capabilityInstallations
            .filter { $0.capabilityID == capabilityID }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
            .first
    }

    @discardableResult
    func registerWorkflowCapabilityInstallation(_ installation: DesktopWorkflowCapabilityInstallationRecord) -> Bool {
        guard installation.capabilityID.range(
            of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else { return false }
        return mutate { state in
            if let index = state.operations.workflows.capabilityInstallations.firstIndex(where: { $0.id == installation.id }) {
                guard state.operations.workflows.capabilityInstallations[index].packageDigest == installation.packageDigest,
                      state.operations.workflows.capabilityInstallations[index].executableDigest == installation.executableDigest else {
                    return
                }
                state.operations.workflows.capabilityInstallations[index] = installation
            } else {
                state.operations.workflows.capabilityInstallations.append(installation)
            }
            state.appendAudit(
                domain: "workflow-capability",
                action: "install",
                target: installation.id,
                state: .completed,
                detail: "Installed disabled with \(installation.trust.label.lowercased()) trust.",
                recordedAtUnixMillis: self.now()
            )
        }
    }

    func setWorkflowCapabilityEnabled(id: String, enabled: Bool) -> Bool {
        guard let installation = snapshot.operations.workflows.capabilityInstallations.first(where: { $0.id == id }),
              !enabled || installation.trust == .kanameBuiltIn || installation.lastTestPassed else { return false }
        return mutateRecord(at: \.operations.workflows.capabilityInstallations, id: id) { $0.enabled = enabled }
    }

    func recordWorkflowCapabilityTest(id: String, passed: Bool) -> Bool {
        let timestamp = now()
        return mutateRecord(at: \.operations.workflows.capabilityInstallations, id: id) {
            $0.lastTestedAtUnixMillis = timestamp
            $0.lastTestPassed = passed
            if !passed { $0.enabled = false }
        }
    }

    @discardableResult
    func claimWorkflowRun(runID: String, ownerID: String, leaseMilliseconds: Int64) -> String? {
        let cleanOwner = ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = now()
        guard !cleanOwner.isEmpty, cleanOwner.utf8.count <= 256, leaseMilliseconds >= 5_000,
              snapshot.operations.workflows.runs.contains(where: {
                  $0.id == runID && ($0.state == .queued || $0.state == .running)
              }), !snapshot.operations.workflows.runtimeClaims.contains(where: {
                  $0.runID == runID && $0.state == .active && $0.leaseDeadlineUnixMillis > timestamp
              }) else { return nil }
        let claim = DesktopWorkflowRuntimeClaimRecord(
            id: UUID().uuidString.lowercased(),
            runID: runID,
            ownerID: cleanOwner,
            state: .active,
            claimedAtUnixMillis: timestamp,
            heartbeatAtUnixMillis: timestamp,
            leaseDeadlineUnixMillis: timestamp + min(leaseMilliseconds, 300_000),
            releasedAtUnixMillis: nil
        )
        guard mutate({ state in
            for index in state.operations.workflows.runtimeClaims.indices
                where state.operations.workflows.runtimeClaims[index].runID == runID
                    && state.operations.workflows.runtimeClaims[index].state == .active {
                state.operations.workflows.runtimeClaims[index].state = .expired
                state.operations.workflows.runtimeClaims[index].releasedAtUnixMillis = timestamp
            }
            state.operations.workflows.runtimeClaims.append(claim)
        }) else { return nil }
        return claim.id
    }

    func heartbeatWorkflowRunClaim(id: String, ownerID: String, leaseMilliseconds: Int64) -> Bool {
        let timestamp = now()
        guard let claim = snapshot.operations.workflows.runtimeClaims.first(where: {
            $0.id == id && $0.ownerID == ownerID && $0.state == .active && $0.leaseDeadlineUnixMillis >= timestamp
        }), snapshot.operations.workflows.runs.contains(where: {
            $0.id == claim.runID && ($0.state == .queued || $0.state == .running)
        }) else { return false }
        return mutateRecord(at: \.operations.workflows.runtimeClaims, id: id) {
            $0.heartbeatAtUnixMillis = timestamp
            $0.leaseDeadlineUnixMillis = timestamp + min(max(leaseMilliseconds, 5_000), 300_000)
        }
    }

    func releaseWorkflowRunClaim(id: String, ownerID: String) -> Bool {
        let timestamp = now()
        guard snapshot.operations.workflows.runtimeClaims.contains(where: {
            $0.id == id && $0.ownerID == ownerID && $0.state == .active
        }) else { return false }
        return mutateRecord(at: \.operations.workflows.runtimeClaims, id: id) {
            $0.state = .released
            $0.releasedAtUnixMillis = timestamp
        }
    }

    @discardableResult
    func recoverExpiredWorkflowClaims() -> Int {
        let timestamp = now()
        let expired = snapshot.operations.workflows.runtimeClaims.filter {
            $0.state == .active && $0.leaseDeadlineUnixMillis < timestamp
        }
        guard !expired.isEmpty else { return 0 }
        let runIDs = Set(expired.map(\.runID))
        guard mutate({ state in
            for index in state.operations.workflows.runtimeClaims.indices
                where runIDs.contains(state.operations.workflows.runtimeClaims[index].runID)
                    && state.operations.workflows.runtimeClaims[index].state == .active {
                state.operations.workflows.runtimeClaims[index].state = .expired
                state.operations.workflows.runtimeClaims[index].releasedAtUnixMillis = timestamp
            }
            for attemptIndex in state.operations.workflows.stepAttempts.indices
                where runIDs.contains(state.operations.workflows.stepAttempts[attemptIndex].runID)
                    && state.operations.workflows.stepAttempts[attemptIndex].state == .running {
                let attempt = state.operations.workflows.stepAttempts[attemptIndex]
                let run = state.operations.workflows.runs.first(where: { $0.id == attempt.runID })
                let step = run.flatMap { run in
                    state.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID })?
                        .steps.first(where: { $0.id == attempt.stepID })
                }
                state.operations.workflows.stepAttempts[attemptIndex].state = .failed
                state.operations.workflows.stepAttempts[attemptIndex].errorSummary = "The workflow worker lease expired."
                state.operations.workflows.stepAttempts[attemptIndex].completedAtUnixMillis = timestamp
                if let runIndex = state.operations.workflows.runs.firstIndex(where: { $0.id == attempt.runID }) {
                    state.operations.workflows.runs[runIndex].currentStepID = nil
                    state.operations.workflows.runs[runIndex].state = step?.isIdempotent == true ? .queued : .failed
                }
                if let workItemID = run?.workItemID,
                   let itemIndex = state.operations.workflows.workItems.firstIndex(where: { $0.id == workItemID }) {
                    state.operations.workflows.workItems[itemIndex].state = step?.isIdempotent == true ? .preparing : .needsAttention
                    state.operations.workflows.workItems[itemIndex].nextAction = step?.isIdempotent == true
                        ? "The interrupted idempotent step is ready to resume."
                        : "Review the interrupted non-idempotent step before any retry."
                    state.operations.workflows.workItems[itemIndex].updatedAtUnixMillis = timestamp
                }
            }
        }) else { return 0 }
        return expired.count
    }

    func interruptWorkflowStepForHost(attemptID: String, reason: String) -> Bool {
        guard let attempt = snapshot.operations.workflows.stepAttempts.first(where: {
            $0.id == attemptID && $0.state == .running
        }), let run = snapshot.operations.workflows.runs.first(where: { $0.id == attempt.runID }) else { return false }
        return persistWorkflowHostStepTransition(
            attemptID: attemptID,
            runID: run.id,
            workItemID: run.workItemID,
            stepID: attempt.stepID,
            transition: .wait(reason: reason)
        )
    }

    func resumeWorkflowStepAfterEffect(
        runID: String,
        stepID: String,
        outputDigest: String,
        artifactIDs: [String] = []
    ) -> Bool {
        guard let attempt = snapshot.operations.workflows.stepAttempts
            .filter({ $0.runID == runID && $0.stepID == stepID && $0.state == .waiting })
            .max(by: { $0.attempt < $1.attempt }),
              let run = snapshot.operations.workflows.runs.first(where: { $0.id == runID && $0.state == .waiting }),
              !outputDigest.isEmpty else { return false }
        return persistWorkflowHostStepTransition(
            attemptID: attempt.id,
            runID: runID,
            workItemID: run.workItemID,
            stepID: stepID,
            transition: .complete(outputDigest: outputDigest, artifactIDs: artifactIDs)
        )
    }

    private func persistWorkflowHostStepTransition(
        attemptID: String,
        runID: String,
        workItemID: String,
        stepID: String,
        transition: WorkflowHostStepTransition
    ) -> Bool {
        let timestamp = now()
        return mutate {
            $0.applyWorkflowHostStepTransition(
                attemptID: attemptID,
                runID: runID,
                workItemID: workItemID,
                stepID: stepID,
                transition: transition,
                timestamp: timestamp
            )
        }
    }

    func workflowMigrationReadiness(workflowID: String) -> DesktopWorkflowMigrationReadinessReport {
        guard let definition = snapshot.operations.workflows.definitions.first(where: { $0.id == workflowID }),
              let revision = snapshot.operations.workflows.revisions.first(where: { $0.id == definition.currentRevisionID }) else {
            return DesktopWorkflowMigrationReadinessReport(workflowID: workflowID, checks: [
                .init(id: "definition", title: "Workflow definition", detail: "Install a valid workflow package first.", state: .blocked),
            ])
        }
        var checks: [DesktopWorkflowMigrationReadinessCheck] = [
            .init(
                id: "definition",
                title: "Immutable workflow contract",
                detail: "Revision \(revision.version) is installed with digest \(String(revision.manifestDigest.prefix(12))).",
                state: .ready
            ),
        ]
        if revision.schemaVersion >= 2 {
            checks.append(.init(
                id: "typed-graph", title: "Typed execution graph",
                detail: "Every non-terminal stage declares bounded, schema-evaluated transitions with durable decisions.",
                state: .ready
            ))
        } else {
            checks.append(.init(
                id: "typed-graph", title: "Ordered compatibility runtime",
                detail: "This package uses the linear v1 runtime. Repackage as v2 to use decisions, structured reviews, and resumable subscriptions.",
                state: .attention
            ))
        }
        if revision.steps.contains(where: { $0.reviewContract != nil }) {
            checks.append(.init(
                id: "structured-review", title: "Structured review",
                detail: "Editable decisions are schema-checked, digest-bound, and validation-aware.", state: .ready
            ))
        }
        if revision.steps.contains(where: { $0.waitContract != nil }) {
            checks.append(.init(
                id: "resumable-waits", title: "Resumable external waits",
                detail: "Subscriptions preserve correlation, deadline, supersession, and the event that resumed the run.", state: .ready
            ))
        }
        if let datasets = revision.datasetDefinitions, !datasets.isEmpty {
            checks.append(.init(
                id: "datasets", title: "Workflow datasets",
                detail: "\(datasets.count) schema-validated dataset\(datasets.count == 1 ? "" : "s") use transactional unique-key upserts.",
                state: .ready
            ))
        }
        if revision.steps.contains(where: { $0.kind == .effect }) {
            checks.append(.init(
                id: "connector-effects", title: "Connector effect boundary",
                detail: "Effects require a trusted preview, exact approval or bounded grant, idempotency, execution, and reconciliation.",
                state: .ready
            ))
        }
        if revision.steps.contains(where: { $0.kind == .agent }) {
            let policies = revision.steps.compactMap(\.agentPolicy)
            let allowed = Set(policies.flatMap(\.allowedCapabilityIDs))
            let unavailable = allowed.filter { capabilityID in
                guard let installation = workflowCapabilityInstallation(capabilityID: capabilityID) else { return true }
                return !installation.enabled || !installation.lastTestPassed
                    || installation.permissions.permissions.contains(where: {
                        [.externalEffects, .emailDraft, .emailSend, .emailLabels].contains($0)
                    })
            }
            checks.append(.init(
                id: "bounded-agent", title: "Bounded agent runtime",
                detail: unavailable.isEmpty
                    ? "Every allowed tool is installed and tested; token, tool-call, time, output, and direct-effect limits are enforced."
                    : "Review or replace unavailable or effect-capable agent tools: \(unavailable.sorted().joined(separator: ", ")).",
                state: unavailable.isEmpty ? .ready : .blocked
            ))
        }
        for capabilityID in Set(revision.steps.compactMap(\.capabilityID)).sorted() {
            let installation = workflowCapabilityInstallation(capabilityID: capabilityID)
            let state: DesktopWorkflowMigrationReadinessState
            let detail: String
            if let installation, installation.enabled, installation.lastTestPassed,
               !installation.permissions.broadens(revision.permissions) {
                state = installation.trust == .localDigest ? .attention : .ready
                detail = "\(installation.name) \(installation.version) is enabled, tested, and \(installation.trust.label.lowercased())."
            } else if let installation, !installation.enabled || !installation.lastTestPassed {
                state = .blocked
                detail = "\(installation.name) is installed but must pass its local test and be enabled."
            } else {
                state = .blocked
                detail = "Install and review capability \(capabilityID)."
            }
            checks.append(.init(id: "capability:\(capabilityID)", title: capabilityID, detail: detail, state: state))
        }
        if revision.steps.contains(where: { $0.kind == .sendEmail }) {
            checks.append(.init(
                id: "email-threading",
                title: "Threaded email with attachments",
                detail: "Kaname binds thread ID, reply headers, recipients, body, and attachment digests, then re-reads Gmail and verifies recipients, subject, thread, headers, names, and attachment bytes.",
                state: .ready
            ))
        }
        if definition.triggerKinds.contains(.manual) {
            checks.append(.init(
                id: "manual-trigger", title: "Manual run",
                detail: "Run creates a durable user-supplied event, work item, episode, frozen context, and exact-revision run.",
                state: .ready
            ))
        }
        for unsupported in [DesktopWorkflowTriggerKind.schedule, .calendar]
            where definition.triggerKinds.contains(unsupported) {
            checks.append(.init(
                id: "trigger:\(unsupported.rawValue)", title: "\(unsupported.label) trigger",
                detail: "This trigger is declared by the package but is not connected to the production workflow dispatcher.",
                state: .blocked
            ))
        }
        if definition.triggerKinds.contains(.email) {
            let bindings = workflowTriggerBindings(workflowID: workflowID).filter { $0.trigger == .email }
            let enabledBindings = bindings.filter(\.enabled)
            let triggerState: DesktopWorkflowMigrationReadinessState = bindings.isEmpty || enabledBindings.isEmpty
                ? .blocked
                : enabledBindings.allSatisfy { $0.lastCursor != nil } ? .ready : .attention
            checks.append(.init(
                id: "email-trigger",
                title: "Durable email trigger",
                detail: bindings.isEmpty
                    ? "Configure an account-scoped Gmail history binding and test its filter before enabling it."
                    : enabledBindings.isEmpty
                        ? "\(bindings.count) account-scoped binding\(bindings.count == 1 ? " is" : "s are") configured but disabled."
                        : enabledBindings.allSatisfy { $0.lastCursor != nil }
                            ? "\(enabledBindings.count) enabled Gmail history binding\(enabledBindings.count == 1 ? " has" : "s have") a durable cursor."
                            : "The enabled binding will establish its start cursor without importing old mail on the next check.",
                state: triggerState
            ))
        }
        checks.append(.init(
            id: "storage",
            title: "Private workflow storage",
            detail: "State and content-addressed artifacts are namespaced, backup-aware, and excluded from reusable packages.",
            state: .ready
        ))
        checks.append(.init(
            id: "recovery",
            title: "Crash-safe execution",
            detail: "Durable leases recover interrupted idempotent work and stop non-idempotent work for review.",
            state: .ready
        ))
        return DesktopWorkflowMigrationReadinessReport(workflowID: workflowID, checks: checks)
    }
}
