import AppKit
import CryptoKit
import Foundation
import KanameConnectivity
import KanameDesktop

private func withWorkflowAgentTimeout<Value: Sendable>(
    seconds: Int,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    do {
        return try await AsyncDeadline.first(timeout: .seconds(seconds), operation: operation)
    } catch AsyncDeadlineError.timedOut {
        throw DesktopWorkflowCapabilityError.executionFailed(
            "The bounded agent exhausted its reviewed wall-clock budget."
        )
    }
}

@MainActor
public final class DesktopMailViewModel: ObservableObject {
    @Published public private(set) var threads: [GmailThreadDetailSnapshot] = []
    @Published public private(set) var selectedThread: GmailThreadDetailSnapshot?
    @Published public private(set) var labels: [String: [GmailLabelSnapshot]] = [:]
    @Published public private(set) var nextPageTokens: [String: String] = [:]
    @Published public private(set) var failedAccounts: [String] = []
    @Published public private(set) var isBusy = false
    @Published public private(set) var message: String?
    @Published public private(set) var activeActionID: String?
    @Published public private(set) var localSummary: String?
    @Published public private(set) var workflowComponentIssues: [String] = []
    @Published public var query = "in:inbox"

    private let service: NativeGoogleIntegrationService
    private let mailAdapter: any MailProviderAdapter
    private let environment: KanameDesktopEnvironment
    private var workflowMonitoringTask: _Concurrency.Task<Void, Never>?
    private var workflowRuntime: DesktopWorkflowRuntime?
    private var workflowEffectCoordinator: DesktopWorkflowEffectCoordinator?

    public init(
        environment: KanameDesktopEnvironment = .current,
        googleClientConfiguration: GoogleOAuthClientConfiguration? = nil
    ) {
        self.environment = environment
        let service = NativeGoogleIntegrationService(
            rootDirectory: environment.googleDirectory,
            keychainService: environment.googleKeychainService,
            clientConfiguration: googleClientConfiguration
        )
        self.service = service
        mailAdapter = GmailMailProviderAdapter(service: service)
    }

    public func startWorkflowMonitoring(model: DesktopAppModel) {
        guard workflowMonitoringTask == nil,
              !CommandLine.arguments.contains("--snapshot") else { return }
        workflowMonitoringTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            await runWorkflowMaintenanceCycle(model: model)
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .seconds(60))
                guard !_Concurrency.Task.isCancelled else { return }
                await runWorkflowMaintenanceCycle(model: model)
            }
        }
    }

    public func runWorkflowMaintenanceCycle(model: DesktopAppModel) async {
        _ = model.expireWorkflowAuthorityGrants()
        _ = model.recoverExpiredWorkflowClaims()
        _ = model.expireWorkflowWaits()
        await refreshMailProviderReadiness(model: model)
        dispatchDueSchedules(model: model)
        await pollWorkflowBindings(model: model, announce: false)
        await executeQueuedWorkflowRuns(model: model)
    }

    private func refreshMailProviderReadiness(model: DesktopAppModel) async {
        for installation in model.workflowInstallations {
            guard let revision = model.snapshot.operations.workflows.revisions.first(where: {
                $0.id == installation.workflowRevisionID
            }), let bindings = model.currentWorkflowBindings(installationID: installation.id) else { continue }
            let requirements = (revision.providerFeatures ?? []).filter { $0.providerKind == "mail" }
            guard !requirements.isEmpty else { continue }
            let featureIDs = Set(requirements.map(\.id))
            let mailSlots = Set((revision.bindingSlots ?? []).filter {
                $0.providerFeatureID.map(featureIDs.contains) == true
            }.map(\.id))
            let resourceBindings = bindings.resolutions.filter {
                mailSlots.contains($0.slotID) && [.providerResource, .folder].contains($0.kind)
            }
            let accountIDs = bindings.resolutions.filter {
                $0.kind == .account && (mailSlots.isEmpty || mailSlots.contains($0.slotID))
            }.flatMap(\.resourceIDs)
            var issues: [String] = []
            if accountIDs.isEmpty { issues.append("Select a logical mail account.") }
            for accountID in accountIDs {
                do {
                    let readiness = try await mailAdapter.readiness(accountID: accountID)
                    for requirement in requirements where requirement.required {
                        guard let feature = mailFeature(requirement.feature) else {
                            issues.append("Unknown required mail feature \(requirement.feature).")
                            continue
                        }
                        guard let status = readiness.feature(feature), status.ready else {
                            let missing = readiness.feature(feature)?.missingScopes.joined(separator: ", ") ?? "unsupported"
                            issues.append("\(accountID) cannot provide \(requirement.feature): \(missing).")
                            continue
                        }
                    }
                    if !resourceBindings.isEmpty {
                        let available = Set(try await mailAdapter.resources(accountID: accountID).map(\.id))
                        for binding in resourceBindings {
                            let missing = binding.resourceIDs.filter { !available.contains($0) }
                            if !missing.isEmpty {
                                issues.append("\(accountID) is missing bound resource IDs: \(missing.sorted().joined(separator: ", ")).")
                            }
                        }
                    }
                } catch {
                    issues.append("\(accountID) readiness could not be verified: \(error.localizedDescription)")
                }
            }
            _ = model.recordWorkflowProviderReadiness(installationID: installation.id, issues: issues)
        }
    }

    private func mailFeature(_ identifier: String) -> MailProviderFeature? {
        if let exact = MailProviderFeature(rawValue: identifier) { return exact }
        return switch identifier {
        case "search": .boundedSearch
        case "read", "thread-read": .conversationRead
        case "history", "delta": .deltaSync
        case "resources", "labels", "folders", "logical-label-binding": .logicalResourceBinding
        case "attachments": .attachmentFetch
        case "mutate", "effects": .conversationMutation
        default: nil
        }
    }

    public func checkWorkflowTriggers(model: DesktopAppModel) {
        _Concurrency.Task { await pollWorkflowBindings(model: model, announce: true) }
    }

    public func processExistingWorkflowMatches(
        model: DesktopAppModel,
        binding: DesktopWorkflowTriggerBindingRecord
    ) {
        guard !isBusy, binding.trigger == .email, ["mail", "gmail"].contains(binding.source),
              let accountID = binding.accountIDs.first else { return }
        isBusy = true
        _Concurrency.Task {
            do {
                let matches = try await matchingMailConversationIDs(
                    accountID: accountID, query: binding.sourceFilter
                ).sorted()
                let alert = NSAlert()
                alert.messageText = "Process \(matches.count) existing mail match\(matches.count == 1 ? "" : "es")?"
                alert.informativeText = "Account: \(accountID)\nFilter: \(binding.sourceFilter)\n\nThis creates durable workflow episodes for the exact current matches. It does not archive, label, trash, mark read, draft, or send email."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Process existing matches")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    message = "Existing-mail processing cancelled; Gmail was not changed."
                    isBusy = false
                    return
                }
                let cursor = try await mailAdapter.currentCursor(accountID: accountID)
                var ownership: [String: DesktopWorkflowOwnershipPolicyRecord] = [:]
                let policies = model.snapshot.operations.workflows.ownershipPolicies
                    .filter { $0.enabled && $0.accountID == accountID }
                    .sorted { ($0.priority, $0.id) > ($1.priority, $1.id) }
                for policy in policies {
                    let threadIDs = try await matchingMailConversationIDs(
                        accountID: accountID, query: policy.sourceFilter
                    )
                    for threadID in threadIDs where ownership[threadID] == nil { ownership[threadID] = policy }
                }
                var ingested = 0
                for conversationID in matches {
                    let conversation = try await mailAdapter.conversation(
                        accountID: accountID, conversationID: conversationID
                    )
                    guard mayObserveWorkflowThread(
                        conversation, binding: binding, matchingPolicy: ownership[conversation.id], model: model
                    ) else { continue }
                    guard let latest = conversation.messages.last else { continue }
                    let event = MailDeltaEvent(
                        id: "backfill:\(accountID):\(latest.id)", cursor: conversation.cursor ?? cursor,
                        kind: .messageAdded, messageID: latest.id, conversationID: conversation.id,
                        resourceIDs: latest.resourceIDs
                    )
                    if try await ingestWorkflowThread(
                        conversation, event: event, binding: binding, cursor: cursor, model: model
                    ) { ingested += 1 }
                }
                _ = model.advanceWorkflowTriggerCursor(id: binding.id, cursor: cursor)
                message = "Created \(ingested) workflow episode\(ingested == 1 ? "" : "s") from \(matches.count) exact existing match\(matches.count == 1 ? "" : "es"). The mail provider was not changed."
                await executeQueuedWorkflowRuns(model: model)
            } catch {
                message = "Existing-mail processing stopped safely: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    @discardableResult
    public func runWorkflowManually(
        model: DesktopAppModel,
        workflowID: String,
        title: String,
        request: String,
        input: Data
    ) -> Bool {
        guard !isBusy,
              (try? JSONSerialization.jsonObject(with: input, options: [.fragmentsAllowed])) != nil,
              let storage = model.workflowStorage(workflowID: workflowID) else {
            message = "Enter valid JSON input before starting this workflow."
            return false
        }
        if let definition = model.snapshot.operations.workflows.definitions.first(where: { $0.id == workflowID }),
           let revision = model.snapshot.operations.workflows.revisions.first(where: { $0.id == definition.currentRevisionID }),
           let schema = revision.manualRunInputSchema,
           let issue = DesktopWorkflowJSONSchemaValidator.validationDiagnostics(instance: input, against: schema).first {
            message = "Manual input \(issue.path.isEmpty ? "/" : issue.path): \(issue.message)"
            return false
        }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let digest = DesktopWorkflowPackageCodec.digest(input)
        guard let eventID = model.observeWorkflowExternalEvent(
            source: "manual", accountID: "local-user", conversationID: nil, messageID: nil,
            cursor: nil, payloadDigest: digest,
            deduplicationKey: "manual:\(workflowID):\(UUID().uuidString.lowercased())"
        ), let workItemID = model.createWorkflowWorkItem(workflowID: workflowID, title: title, goal: request),
        let episodeID = model.createWorkflowEpisode(
            workItemID: workItemID, sourceEventID: eventID, sourceMessageID: nil,
            intent: .request, summary: title, deltaSummary: "User-started workflow run"
        ), let artifact = try? storage.importArtifact(
            data: input, filename: "manual-input.json", mediaType: "application/json",
            createdAtUnixMillis: timestamp
        ) else {
            message = "Kaname could not create the durable manual workflow input."
            return false
        }
        _ = model.bindWorkflowArtifactRole(
            workflowID: workflowID, workItemID: workItemID, episodeID: episodeID,
            role: "trigger-payload", artifact: artifact, createdByRunID: "manual:\(eventID)"
        )
        guard let contextID = model.compileWorkflowContext(
            workItemID: workItemID, episodeID: episodeID, request: request,
            references: [DesktopWorkflowContextReference.reference(
                id: eventID, kind: "manual-input", label: title, sourceID: "manual:\(eventID)",
                digest: artifact.sha256, included: true,
                reason: "Exact user-supplied input for this manual run.",
                estimatedTokens: max(1, min(input.count / 4, 8_000)),
                content: String(data: input, encoding: .utf8)
            )]
        ), model.queueWorkflowRun(
            workItemID: workItemID, episodeID: episodeID, contextSnapshotID: contextID
        ) != nil else {
            message = "Kaname stored the manual input but could not queue its run."
            return false
        }
        message = "Manual workflow run queued."
        _Concurrency.Task { await executeQueuedWorkflowRuns(model: model) }
        return true
    }

    private func pollWorkflowBindings(model: DesktopAppModel, announce: Bool) async {
        let definitions = Dictionary(uniqueKeysWithValues: model.workflowDefinitions.map { ($0.id, $0) })
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let health = Dictionary(uniqueKeysWithValues: model.workflowTriggerHealth.map { ($0.bindingID, $0) })
        let eligibleBindings = model.workflowTriggerBindings().filter {
            $0.enabled && definitions[$0.workflowID]?.enabled == true
                && (health[$0.id]?.nextAttemptAtUnixMillis ?? Int64.min) <= timestamp
        }
        let emailBindings = eligibleBindings.filter { $0.trigger == .email && ["mail", "gmail"].contains($0.source) }
        let calendarBindings = eligibleBindings.filter {
            $0.trigger == .calendar && $0.source == "google-calendar"
        }
        guard !emailBindings.isEmpty || !calendarBindings.isEmpty else { return }
        var observedEpisodes = 0
        var failures: [String] = []
        var ownershipByAccount: [String: [String: DesktopWorkflowOwnershipPolicyRecord]] = [:]
        for binding in emailBindings {
            for accountID in binding.accountIDs {
                do {
                    let ownership: [String: DesktopWorkflowOwnershipPolicyRecord]
                    if let cached = ownershipByAccount[accountID] {
                        ownership = cached
                    } else {
                        var resolved: [String: DesktopWorkflowOwnershipPolicyRecord] = [:]
                        let policies = model.snapshot.operations.workflows.ownershipPolicies
                            .filter { $0.enabled && $0.accountID == accountID }
                            .sorted { ($0.priority, $0.id) > ($1.priority, $1.id) }
                        for policy in policies {
                            let threadIDs = try await matchingMailConversationIDs(
                                accountID: accountID, query: policy.sourceFilter
                            )
                            for threadID in threadIDs where resolved[threadID] == nil {
                                resolved[threadID] = policy
                            }
                        }
                        ownership = resolved
                        ownershipByAccount[accountID] = resolved
                    }
                    guard let cursor = binding.lastCursor else {
                        _ = model.advanceWorkflowTriggerCursor(
                            id: binding.id,
                            cursor: try await mailAdapter.currentCursor(accountID: accountID)
                        )
                        _ = model.recordWorkflowTriggerSuccess(bindingID: binding.id, accountID: accountID)
                        continue
                    }
                    let matching = try await matchingMailConversationIDs(
                        accountID: accountID,
                        query: binding.sourceFilter
                    )
                    let observation = try await MailDeltaObserver(adapter: mailAdapter).observe(
                        accountID: accountID,
                        startCursor: cursor,
                        kinds: [.messageAdded]
                    )
                    switch observation {
                    case let .events(events, nextCursor):
                        for event in events where matching.contains(event.conversationID) {
                            let conversation = try await mailAdapter.conversation(
                                accountID: accountID, conversationID: event.conversationID
                            )
                            guard mayObserveWorkflowThread(
                                conversation, binding: binding, matchingPolicy: ownership[conversation.id], model: model
                            ) else { continue }
                            if try await ingestWorkflowThread(
                                conversation,
                                event: event,
                                binding: binding,
                                cursor: nextCursor,
                                model: model
                            ) { observedEpisodes += 1 }
                        }
                        _ = model.advanceWorkflowTriggerCursor(id: binding.id, cursor: nextCursor)
                        _ = model.recordWorkflowTriggerSuccess(
                            bindingID: binding.id, accountID: accountID,
                            cursorLagEstimate: events.count
                        )
                    case .fullSyncRequired:
                        for threadID in matching.sorted() {
                            let conversation = try await mailAdapter.conversation(
                                accountID: accountID, conversationID: threadID
                            )
                            guard mayObserveWorkflowThread(
                                conversation, binding: binding, matchingPolicy: ownership[conversation.id], model: model
                            ) else { continue }
                            guard let latest = conversation.messages.last else { continue }
                            let event = MailDeltaEvent(
                                id: "full-sync:\(accountID):\(latest.id)",
                                cursor: conversation.cursor ?? cursor,
                                kind: .messageAdded,
                                messageID: latest.id,
                                conversationID: conversation.id,
                                resourceIDs: latest.resourceIDs
                            )
                            if try await ingestWorkflowThread(
                                conversation,
                                event: event,
                                binding: binding,
                                cursor: conversation.cursor ?? cursor,
                                model: model
                            ) { observedEpisodes += 1 }
                        }
                        _ = model.advanceWorkflowTriggerCursor(
                            id: binding.id,
                            cursor: try await mailAdapter.currentCursor(accountID: accountID)
                        )
                        _ = model.recordWorkflowTriggerSuccess(
                            bindingID: binding.id, accountID: accountID,
                            cursorLagEstimate: matching.count
                        )
                    }
                } catch {
                    failures.append("\(binding.workflowID): \(error.localizedDescription)")
                    let detail = error.localizedDescription
                    let lower = detail.lowercased()
                    _ = model.recordWorkflowTriggerFailure(
                        bindingID: binding.id, code: String(reflecting: type(of: error)),
                        summary: detail, accountID: accountID,
                        authenticationRequired: lower.contains("authoriz") || lower.contains("authentic")
                            || lower.contains("credential") || lower.contains("token")
                    )
                }
            }
        }
        for binding in calendarBindings {
            for accountID in binding.accountIDs {
                do {
                    let observation = try await service.observeCalendarEvents(
                        accountID: accountID,
                        calendarID: binding.sourceFilter,
                        syncToken: binding.lastCursor
                    )
                    if binding.lastCursor != nil {
                        for event in observation.events {
                            if ingestWorkflowCalendarEvent(event, binding: binding, model: model) {
                                observedEpisodes += 1
                            }
                        }
                    }
                    _ = model.advanceWorkflowTriggerCursor(
                        id: binding.id, cursor: observation.nextSyncToken
                    )
                    _ = model.recordWorkflowTriggerSuccess(
                        bindingID: binding.id, accountID: accountID,
                        cursorLagEstimate: observation.events.count
                    )
                } catch {
                    failures.append("\(binding.workflowID): \(error.localizedDescription)")
                    let detail = error.localizedDescription
                    let lower = detail.lowercased()
                    _ = model.recordWorkflowTriggerFailure(
                        bindingID: binding.id,
                        code: String(reflecting: type(of: error)), summary: detail,
                        accountID: accountID,
                        authenticationRequired: lower.contains("authoriz") || lower.contains("authentic")
                            || lower.contains("credential") || lower.contains("token")
                    )
                }
            }
        }
        if announce {
            message = failures.isEmpty
                ? "Workflow triggers are current; \(observedEpisodes) new episode\(observedEpisodes == 1 ? "" : "s") observed."
                : "Observed \(observedEpisodes) new episode(s). \(failures.count) scoped trigger(s) need attention."
        }
        await executeQueuedWorkflowRuns(model: model)
    }

    private func ingestWorkflowCalendarEvent(
        _ event: CalendarEventSnapshot,
        binding: DesktopWorkflowTriggerBindingRecord,
        model: DesktopAppModel
    ) -> Bool {
        guard let storage = model.workflowStorage(workflowID: binding.workflowID) else { return false }
        let payloadObject: [String: Any] = [
            "provider": event.provider.rawValue,
            "accountID": event.accountID,
            "calendarID": event.calendarID,
            "eventID": event.eventID,
            "revision": event.revision,
            "title": event.title,
            "startAtUnixMillis": event.startAtUnixMillis,
            "endAtUnixMillis": event.endAtUnixMillis,
            "timeZoneIdentifier": event.timeZoneIdentifier,
            "isAllDay": event.isAllDay,
            "recurrence": event.recurrence,
        ]
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let eventDigest = SHA256.hash(data: Data(event.eventID.utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        let revisionDigest = SHA256.hash(data: Data(event.revision.utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        guard let payload = try? JSONSerialization.data(
            withJSONObject: payloadObject, options: [.sortedKeys, .withoutEscapingSlashes]
        ), let artifact = try? storage.importArtifact(
            data: payload,
            filename: "calendar-\(eventDigest)-\(revisionDigest).json",
            mediaType: "application/json", createdAtUnixMillis: timestamp
        ), let eventID = model.observeWorkflowExternalEvent(
            source: "google-calendar", accountID: event.accountID,
            conversationID: "\(event.calendarID):\(event.eventID)",
            messageID: event.revision, cursor: binding.lastCursor,
            payloadDigest: artifact.sha256,
            deduplicationKey: "google-calendar:\(event.accountID):\(event.calendarID):\(event.eventID):\(event.revision)"
        ) else { return false }
        if model.snapshot.operations.workflows.episodes.contains(where: { $0.sourceEventID == eventID }) {
            return false
        }
        let conversationID = "\(event.calendarID):\(event.eventID)"
        var item = model.workflowWorkItems(accountID: event.accountID, conversationID: conversationID)
            .first { $0.workflowID == binding.workflowID }
        if item == nil, let workItemID = model.createWorkflowWorkItem(
            workflowID: binding.workflowID, title: event.title,
            goal: "Handle changes to this event under the installed workflow contract."
        ) {
            _ = model.bindWorkflowConversation(
                workItemID: workItemID, source: "google-calendar", accountID: event.accountID,
                conversationID: conversationID, relationship: .primary,
                reason: "Matched the reviewed Google Calendar trigger scope.",
                confidence: 1, requiresReview: false,
                firstMessageID: event.revision, latestMessageID: event.revision
            )
            item = model.workflowWorkItems.first { $0.id == workItemID }
        }
        guard let item,
              let episodeID = model.createWorkflowEpisode(
                workItemID: item.id, sourceEventID: eventID, sourceMessageID: event.revision,
                intent: model.workflowEpisodes(workItemID: item.id).isEmpty ? .request : .continuation,
                summary: "Calendar event changed: \(event.title)",
                deltaSummary: "Observed revision \(event.revision)"
              ) else { return false }
        _ = model.bindWorkflowArtifactRole(
            workflowID: binding.workflowID, workItemID: item.id, episodeID: episodeID,
            role: "trigger-payload", artifact: artifact,
            createdByRunID: "google-calendar:\(event.eventID):\(event.revision)"
        )
        guard let contextID = model.compileWorkflowContext(
            workItemID: item.id, episodeID: episodeID,
            request: "Handle the observed change to \(event.title).",
            references: [.reference(
                id: eventID, kind: "calendar-event", label: event.title,
                sourceID: "google-calendar:\(event.accountID):\(event.calendarID):\(event.eventID)",
                digest: artifact.sha256, included: true,
                reason: "Exact incremental Calendar event revision.",
                estimatedTokens: max(1, min(payload.count / 4, 2_000)),
                content: String(data: payload, encoding: .utf8),
                provenance: DesktopWorkflowExternalContentProvenance(
                    sourceID: "google-calendar:\(event.accountID):\(event.calendarID):\(event.eventID)",
                    providerID: "google-calendar", accountID: event.accountID,
                    mediaType: "application/json", digest: artifact.sha256,
                    trust: .untrustedExternalContent
                )
            )]
        ) else { return false }
        return model.queueWorkflowRun(
            workItemID: item.id, episodeID: episodeID, contextSnapshotID: contextID
        ) != nil
    }

    private func mayObserveWorkflowThread(
        _ conversation: MailConversationSnapshot,
        binding: DesktopWorkflowTriggerBindingRecord,
        matchingPolicy: DesktopWorkflowOwnershipPolicyRecord?,
        model: DesktopAppModel
    ) -> Bool {
        if let matchingPolicy,
           matchingPolicy.workflowID != binding.workflowID,
           matchingPolicy.mode != .sharedObservation {
            return false
        }
        let mode: DesktopWorkflowOwnershipMode = matchingPolicy?.workflowID == binding.workflowID
            ? matchingPolicy?.mode ?? .sharedObservation
            : .sharedObservation
        return switch model.claimWorkflowConversation(
            workflowID: binding.workflowID, accountID: conversation.account.localID,
            conversationID: conversation.id, mode: mode
        ) {
        case .acquired, .shared: true
        case .blocked: false
        }
    }

    private func matchingMailConversationIDs(
        accountID: String,
        query: String,
        maximumPages: Int = 20,
        maximumConversations: Int = 2_000
    ) async throws -> Set<String> {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty, cleanQuery.utf8.count <= 2_048 else {
            throw MailProviderAdapterError.invalidIdentifier
        }
        var pageToken: String?
        var seenTokens = Set<String>()
        var identifiers = Set<String>()
        for _ in 0..<min(max(maximumPages, 1), 100) {
            let page = try await mailAdapter.search(
                accountID: accountID,
                query: MailQuery(text: cleanQuery, pageToken: pageToken, limit: 100)
            )
            guard page.failedConversationCount == 0 else {
                throw DesktopWorkflowCapabilityError.executionFailed("The mail provider returned an incomplete search page.")
            }
            identifiers.formUnion(page.conversations.map(\.id))
            guard identifiers.count <= min(max(maximumConversations, 1), 10_000) else {
                throw DesktopWorkflowCapabilityError.executionFailed("The mail filter exceeded its bounded conversation limit.")
            }
            guard let next = page.nextPageToken else { return identifiers }
            guard seenTokens.insert(next).inserted else {
                throw DesktopWorkflowCapabilityError.executionFailed("The mail provider repeated a search page token.")
            }
            pageToken = next
        }
        throw DesktopWorkflowCapabilityError.executionFailed("The mail filter exceeded its bounded page limit.")
    }

    private func dispatchDueSchedules(model: DesktopAppModel) {
        for schedule in model.claimDueWorkflowSchedules() {
            guard let definition = model.workflowDefinitions.first(where: {
                $0.id == schedule.workflowID && $0.enabled
            }), let scheduledAt = schedule.nextRunAtUnixMillis,
                  let storage = model.workflowStorage(workflowID: schedule.workflowID) else { continue }
            let payloadObject: [String: Any] = [
                "trigger": "schedule", "scheduleID": schedule.id,
                "scheduledAtUnixMillis": scheduledAt,
                "timeZoneIdentifier": schedule.timeZoneIdentifier,
            ]
            guard let payload = try? JSONSerialization.data(
                withJSONObject: payloadObject, options: [.sortedKeys, .withoutEscapingSlashes]
            ), let artifact = try? storage.importArtifact(
                data: payload, filename: "schedule-\(schedule.id)-\(scheduledAt).json",
                mediaType: "application/json", createdAtUnixMillis: scheduledAt
            ), let eventID = model.observeWorkflowExternalEvent(
                source: "schedule", accountID: "local", conversationID: schedule.id,
                messageID: "\(scheduledAt)", cursor: "\(scheduledAt)",
                payloadDigest: artifact.sha256,
                deduplicationKey: "workflow-schedule:\(schedule.id):\(scheduledAt)"
            ), let workItemID = model.createWorkflowWorkItem(
                workflowID: definition.id,
                title: "\(definition.name) · \(Date(timeIntervalSince1970: Double(scheduledAt) / 1_000).formatted(date: .abbreviated, time: .shortened))",
                goal: "Run the exact scheduled workflow revision."
            ), let episodeID = model.createWorkflowEpisode(
                workItemID: workItemID, sourceEventID: eventID, sourceMessageID: "\(scheduledAt)",
                intent: .request, summary: "Scheduled invocation", deltaSummary: "Due schedule \(schedule.id)"
            ), let contextID = model.compileWorkflowContext(
                workItemID: workItemID, episodeID: episodeID,
                request: "Run the scheduled workflow.", references: [.reference(
                    id: eventID, kind: "schedule", label: "Scheduled invocation",
                    sourceID: schedule.id, digest: artifact.sha256, included: true,
                    reason: "Exact durable schedule occurrence", estimatedTokens: 32
                )]
            ) else { continue }
            _ = model.queueWorkflowRun(
                workItemID: workItemID, episodeID: episodeID, contextSnapshotID: contextID
            )
        }
    }

    private func ingestWorkflowThread(
        _ conversation: MailConversationSnapshot,
        event: MailDeltaEvent,
        binding: DesktopWorkflowTriggerBindingRecord,
        cursor: String,
        model: DesktopAppModel
    ) async throws -> Bool {
        guard let message = conversation.messages.first(where: { $0.id == event.messageID })
                ?? conversation.messages.last else { return false }
        let policy = model.workflowMailCapturePolicy(
            workflowID: binding.workflowID, accountID: conversation.account.localID
        )
        var attachmentPayloads: [String: Data] = [:]
        var totalAttachmentBytes = 0
        var attachmentCount = 0
        if policy.includeAttachments {
            for threadMessage in conversation.messages {
                for attachment in threadMessage.attachments {
                    guard let maximumBytes = policy.maximumBytesForNextAttachment(
                        mediaType: attachment.mediaType, declaredSize: attachment.size,
                        capturedCount: attachmentCount, capturedBytes: totalAttachmentBytes
                    ) else { continue }
                    let data = try await mailAdapter.attachment(
                        accountID: conversation.account.localID,
                        messageID: attachment.messageID,
                        attachmentID: attachment.attachmentID,
                        maximumBytes: maximumBytes
                    )
                    totalAttachmentBytes += data.count
                    guard totalAttachmentBytes <= policy.maximumTotalBytes else {
                        throw DesktopWorkflowStorageError.quotaExceeded
                    }
                    attachmentPayloads[WorkflowEmailReadResponse.attachmentKey(attachment)] = data
                    attachmentCount += 1
                }
            }
        }
        let payload = try workflowEventPayload(
            conversation: conversation,
            message: message,
            attachmentPayloads: attachmentPayloads,
            policy: policy
        )
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let eventID = model.observeWorkflowExternalEvent(
            source: "mail",
            accountID: conversation.account.localID,
            conversationID: conversation.id,
            messageID: message.id,
            cursor: cursor,
            payloadDigest: digest,
            deduplicationKey: "mail:\(conversation.account.providerID):\(conversation.account.localID):\(message.id)"
        )
        guard let eventID else { return false }
        if model.snapshot.operations.workflows.episodes.contains(where: { $0.sourceEventID == eventID }) { return false }

        var item = model.workflowWorkItems(accountID: conversation.account.localID, conversationID: conversation.id)
            .first(where: { $0.workflowID == binding.workflowID })
        if item == nil,
           let workItemID = model.createWorkflowWorkItem(
               workflowID: binding.workflowID,
               title: message.subject.isEmpty ? "Email workflow" : message.subject,
               goal: "Handle this account-scoped email conversation under the installed workflow contract."
           ) {
            _ = model.bindWorkflowConversation(
                workItemID: workItemID,
                source: "mail",
                accountID: conversation.account.localID,
                conversationID: conversation.id,
                relationship: .primary,
                reason: "Matched the reviewed mail-provider trigger filter.",
                confidence: 1,
                requiresReview: false,
                firstMessageID: message.id,
                latestMessageID: message.id
            )
            item = model.workflowWorkItems.first(where: { $0.id == workItemID })
        }
        guard let item else { return false }
        let priorEpisodes = model.workflowEpisodes(workItemID: item.id)
        guard let episodeID = model.createWorkflowEpisode(
            workItemID: item.id,
            sourceEventID: eventID,
            sourceMessageID: message.id,
            intent: priorEpisodes.isEmpty ? .request : .continuation,
            summary: "New message from \(message.sender): \(message.subject)",
            deltaSummary: priorEpisodes.isEmpty ? "Initial matching request" : "New correlated email input"
        ) else { return false }

        var artifactDigest = digest
        if let storage = model.workflowStorage(workflowID: binding.workflowID),
           let artifact = try? storage.importArtifact(
               data: payload,
               filename: "mail-event-\(message.id).json",
               mediaType: "application/json",
               createdAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
           ) {
            artifactDigest = artifact.sha256
            _ = model.bindWorkflowArtifactRole(
                workflowID: binding.workflowID, workItemID: item.id, episodeID: episodeID,
                role: "trigger-payload", artifact: artifact, createdByRunID: "mail:\(message.id)"
            )
            for threadMessage in conversation.messages {
                for attachment in threadMessage.attachments {
                    guard let data = attachmentPayloads[WorkflowEmailReadResponse.attachmentKey(attachment)],
                          let stored = try? storage.importArtifact(
                              data: data,
                              filename: attachment.filename,
                              mediaType: attachment.mediaType,
                              createdAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
                          ) else { continue }
                    _ = model.bindWorkflowArtifactRole(
                        workflowID: binding.workflowID, workItemID: item.id, episodeID: episodeID,
                        role: "source-attachment-\(stored.sha256.prefix(16))", artifact: stored,
                        createdByRunID: "mail:\(conversation.account.providerID):\(threadMessage.id)"
                    )
                }
            }
        }
        let threadText = workflowThreadText(conversation, policy: policy)
        var contextReferences = priorWorkflowContextReferences(
            model: model, workItemID: item.id, excludingEpisodeID: episodeID
        )
        contextReferences.append(
            DesktopWorkflowContextReference.reference(
                id: eventID,
                kind: "mail-conversation",
                label: message.subject.isEmpty ? "Mail conversation" : message.subject,
                sourceID: "mail:\(conversation.account.providerID):\(conversation.account.localID):\(conversation.id):\(message.id)",
                digest: artifactDigest,
                included: true,
                reason: "Capture-policy-bounded conversation snapshot for the active workflow episode.",
                estimatedTokens: max(1, min(threadText.utf8.count / 4, 24_000)),
                content: threadText,
                provenance: DesktopWorkflowExternalContentProvenance(
                    sourceID: "mail:\(conversation.account.providerID):\(conversation.account.localID):\(conversation.id):\(message.id)",
                    providerID: conversation.account.providerID, accountID: conversation.account.stableID,
                    mediaType: "message/rfc822", digest: artifactDigest,
                    trust: .untrustedExternalContent
                )
            )
        )
        let contextID = model.compileWorkflowContext(
            workItemID: item.id,
            episodeID: episodeID,
            request: policy.capturesMailBody && !message.body.isEmpty
                ? message.body : message.subject,
            references: contextReferences
        )
        if let contextID {
            _ = model.queueWorkflowRun(workItemID: item.id, episodeID: episodeID, contextSnapshotID: contextID)
        }
        return true
    }

    private func workflowEventPayload(
        conversation: MailConversationSnapshot,
        message: MailMessageSnapshot,
        attachmentPayloads: [String: Data],
        policy: DesktopWorkflowCapturePolicy
    ) throws -> Data {
        let headers = policy.capturedHeaders(from: policy.headerAllowlist)
        let includeBody = policy.capturesMailBody
        let messages = conversation.messages.map {
            WorkflowMailPayloadEncoder.messageObject(
                $0, attachmentPayloads: attachmentPayloads,
                headerProjection: headers, includeBody: includeBody
            )
        }
        let object: [String: Any] = [
            "providerID": conversation.account.providerID,
            "accountID": conversation.account.localID,
            "accountIdentity": conversation.accountAddress,
            "conversationID": conversation.id,
            "cursor": conversation.cursor ?? "",
            "triggerMessageID": message.id,
            "messages": messages,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func workflowThreadText(
        _ conversation: MailConversationSnapshot,
        policy: DesktopWorkflowCapturePolicy
    ) -> String {
        let includeBody = policy.capturesMailBody
        return conversation.messages.enumerated().map { index, message in
            """
            Message \(index + 1) [\(message.id)]
            From: \(message.sender)
            To: \(message.recipients)
            Date: \(message.dateDescription)
            Subject: \(message.subject)
            Attachments: \(message.attachments.map(\.filename).joined(separator: ", "))

            \(includeBody ? message.body : "[Body omitted by capture policy]")
            """
        }.joined(separator: "\n\n---\n\n")
    }

    private func priorWorkflowContextReferences(
        model: DesktopAppModel,
        workItemID: String,
        excludingEpisodeID: String
    ) -> [DesktopWorkflowContextReference] {
        model.workflowEpisodes(workItemID: workItemID).filter { $0.id != excludingEpisodeID }.suffix(8).map { episode in
            let content = "Episode \(episode.ordinal) · \(episode.intent.label)\n\(episode.summary)\nDelta: \(episode.deltaSummary)"
            return .reference(
                id: episode.id, kind: "prior-episode", label: "Episode \(episode.ordinal)",
                sourceID: episode.sourceEventID,
                digest: DesktopWorkflowPackageCodec.digest(Data(content.utf8)), included: true,
                reason: "Recent correlated workflow history retained for correction continuity.",
                estimatedTokens: max(1, content.utf8.count / 4), content: content
            )
        }
    }

    private func executeQueuedWorkflowRuns(model: DesktopAppModel) async {
        if workflowRuntime == nil { workflowRuntime = await makeWorkflowRuntime(model: model) }
        guard let workflowRuntime else { return }
        let queued = model.snapshot.operations.workflows.runs.filter { $0.state == .queued }
        for run in queued {
            let input = workflowInput(for: run, model: model)
            _ = await workflowRuntime.executeUntilBlocked(runID: run.id, initialInput: input)
        }
    }

    private func workflowInput(for run: DesktopWorkflowRunRecord, model: DesktopAppModel) -> Data {
        guard let episode = model.snapshot.operations.workflows.episodes.first(where: { $0.id == run.episodeID }),
              let event = model.snapshot.operations.workflows.externalEvents.first(where: { $0.id == episode.sourceEventID }),
              let storage = model.workflowStorage(
                  workflowID: model.snapshot.operations.workflows.workItems.first(where: { $0.id == run.workItemID })?.workflowID ?? ""
              ),
              let data = try? storage.artifactData(sha256: event.payloadDigest) else {
            return Data("{}".utf8)
        }
        return data
    }

    private func makeWorkflowRuntime(model: DesktopAppModel) async -> DesktopWorkflowRuntime? {
        guard let capabilityStore = model.workflowCapabilityStore() else { return nil }
        let fallback = DesktopWorkflowInstalledCapabilityInvoker(
            capabilityStore: capabilityStore,
            scratchRoot: environment.applicationSupportRoot.appendingPathComponent("WorkflowScratch", isDirectory: true),
            workflowInstallationsRoot: environment.applicationSupportRoot.appendingPathComponent("WorkflowInstallations", isDirectory: true)
        )
        let workflowModelWorkspace = environment.applicationSupportRoot
            .appendingPathComponent("WorkflowModelWorkspace", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: workflowModelWorkspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let router = DesktopWorkflowCapabilityRouter(fallback: fallback)
        let effectCoordinator = DesktopWorkflowEffectCoordinator(model: model)
        effectCoordinator.register(DesktopMailWorkflowConnector(adapter: mailAdapter))
        var componentIssues: [String] = []
        for connector in model.snapshot.operations.workflows.connectorInstallations
            .filter({ $0.enabled && $0.qualified }) {
            guard let binding = model.snapshot.operations.workflows.connectorBindings.first(where: {
                $0.connectorID == connector.connectorID && $0.enabled
            }), let capability = model.workflowCapabilityInstallation(capabilityID: connector.connectorID),
                  capability.enabled, capability.lastTestPassed else {
                componentIssues.append("\(connector.name) needs an enabled, qualified capability and binding.")
                continue
            }
            do {
                let directory = capabilityStore.installationDirectory(
                    capabilityID: capability.capabilityID, version: capability.version
                )
                let package = try DesktopWorkflowProcessConnector.loadPackageManifest(from: directory)
                let manifest = try capabilityStore.manifest(for: capability)
                #if canImport(Security)
                let processConnector = try DesktopWorkflowProcessConnector(
                    package: package, capability: manifest, installationDirectory: directory,
                    scratchRoot: environment.applicationSupportRoot.appendingPathComponent("WorkflowScratch", isDirectory: true),
                    binding: binding,
                    secretResolver: DesktopWorkflowKeychainSecretResolver(
                        service: "\(environment.bundleIdentifier).workflow-connector"
                    )
                )
                effectCoordinator.register(processConnector)
                #else
                componentIssues.append("\(connector.name) requires Keychain support on this platform.")
                #endif
            } catch {
                componentIssues.append("\(connector.name): \(error.localizedDescription)")
            }
        }
        workflowComponentIssues = componentIssues
        workflowEffectCoordinator = effectCoordinator
        await router.register(capabilityID: "kaname.context.compile") { invocation, _ in
            .completed(output: invocation.input, artifactIDs: [])
        }
        await router.register(capabilityID: "kaname.artifact.register") { invocation, _ in
            .completed(output: invocation.input, artifactIDs: [])
        }
        await router.register(capabilityID: "kaname.validation.run") { invocation, _ in
            guard let object = try? JSONSerialization.jsonObject(with: invocation.input) as? [String: Any],
                  let instance = object["instance"], let schema = object["schema"],
                  JSONSerialization.isValidJSONObject(instance), JSONSerialization.isValidJSONObject(schema),
                  let instanceData = try? JSONSerialization.data(withJSONObject: instance, options: [.sortedKeys]),
                  let schemaData = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
                  let schemaText = String(data: schemaData, encoding: .utf8),
                  DesktopWorkflowJSONSchemaValidator.validates(instance: instanceData, against: schemaText) else {
                throw DesktopWorkflowCapabilityError.outputInvalid
            }
            return .completed(output: Data("{\"passed\":true}".utf8), artifactIDs: [])
        }
        await router.register(capabilityID: "kaname.model.structured") { invocation, _ in
            let request = try WorkflowStructuredModelRequest.decode(invocation.input)
            let prompt = try request.prompt(including: invocation.contextSnapshot)
            let service = NativeProviderDiscussionService()
            let provider = try request.provider
            let providerText: String
            switch provider {
            case .codex:
                providerText = try await service.runCodex(
                    prompt: prompt,
                    workspace: workflowModelWorkspace,
                    executable: nil
                )
            case let .native(driver):
                providerText = try await service.run(
                    driver: driver,
                    prompt: prompt,
                    workspace: workflowModelWorkspace
                ).text
            }
            let output = try request.validatedOutput(providerText)
            return .completed(output: output, artifactIDs: [])
        }
        await router.register(capabilityID: "kaname.agent.bounded") { [weak model] invocation, _ in
            guard let model, let policy = invocation.step.agentPolicy else {
                throw DesktopWorkflowCapabilityError.executionUnavailable
            }
            guard let callerRevision = await MainActor.run(body: {
                model.snapshot.operations.workflows.runs.first(where: { $0.id == invocation.runID }).flatMap { run in
                    model.snapshot.operations.workflows.revisions.first { $0.id == run.workflowRevisionID }
                }
            }) else { throw DesktopWorkflowCapabilityError.executionUnavailable }
            let request = try WorkflowBoundedAgentRequest.decode(invocation.input)
            let basePrompt = DesktopWorkflowModelContextCompiler.augment(
                prompt: request.prompt, context: invocation.contextSnapshot
            )
            guard let basePrompt else { throw DesktopWorkflowCapabilityError.inputTooLarge }
            let started = Date()
            var transcript: [[String: String]] = []
            var toolCalls = 0
            var estimatedTokens = max(1, basePrompt.utf8.count / 4)
            var artifactIDs: [String] = []
            var artifactMetadata: [DesktopWorkflowStoredArtifact] = []
            var commitProposal = DesktopWorkflowCapabilityCommitProposal()

            for turn in 0...policy.maximumToolCalls {
                guard Date().timeIntervalSince(started) <= Double(policy.timeoutSeconds),
                      estimatedTokens <= policy.maximumModelTokens else {
                    throw DesktopWorkflowCapabilityError.executionFailed("The bounded agent exhausted its reviewed time or model-token budget.")
                }
                let history = transcript.map { "\($0["role"] ?? "event"): \($0["content"] ?? "")" }
                    .joined(separator: "\n")
                let turnPrompt = """
                \(basePrompt)

                You are executing a bounded Kaname workflow agent. Return only JSON matching the supplied action schema.
                To call a tool, return {"kind":"tool","capabilityID":"...","input":<JSON>}.
                To finish, return {"kind":"finish","output":<JSON matching the workflow final schema>}.
                Allowed tool capabilities: \(policy.allowedCapabilityIDs.joined(separator: ", "))
                Remaining tool calls: \(policy.maximumToolCalls - toolCalls)
                Final output schema: \(request.outputSchema)

                Bounded transcript:
                \(history.isEmpty ? "No prior turns." : history)
                """
                let structured = WorkflowStructuredModelRequest(
                    providerName: request.providerName, prompt: turnPrompt,
                    outputSchema: WorkflowAgentAction.schema
                )
                let providerText: String
                let remainingSeconds = max(
                    1,
                    policy.timeoutSeconds - Int(Date().timeIntervalSince(started).rounded(.down))
                )
                let provider = try request.provider
                switch provider {
                case .codex:
                    providerText = try await withWorkflowAgentTimeout(seconds: remainingSeconds) {
                        try await NativeProviderDiscussionService().runCodex(
                            prompt: turnPrompt, workspace: workflowModelWorkspace, executable: nil
                        )
                    }
                case let .native(driver):
                    providerText = try await withWorkflowAgentTimeout(seconds: remainingSeconds) {
                        try await NativeProviderDiscussionService().run(
                            driver: driver, prompt: turnPrompt, workspace: workflowModelWorkspace
                        ).text
                    }
                }
                let actionData = try structured.validatedOutput(providerText)
                estimatedTokens += max(1, providerText.utf8.count / 4)
                let action = try WorkflowAgentAction.decode(actionData)
                transcript.append(["role": "model", "content": String(data: actionData, encoding: .utf8) ?? "{}"])
                switch action.kind {
                case .finish:
                    guard let output = action.output,
                          DesktopWorkflowJSONSchemaValidator.validates(instance: output, against: request.outputSchema) else {
                        throw DesktopWorkflowCapabilityError.outputInvalid
                    }
                    let transcriptData = try JSONSerialization.data(
                        withJSONObject: transcript, options: [.sortedKeys, .withoutEscapingSlashes]
                    )
                    if let storage = await MainActor.run(body: { model.workflowStorage(workflowID: invocation.workflowID) }) {
                        let stored = try storage.importArtifact(
                            data: transcriptData, filename: "agent-\(invocation.runID)-\(invocation.step.id)-transcript.json",
                            mediaType: "application/json",
                            createdAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
                        )
                        artifactIDs.append(stored.sha256)
                        artifactMetadata.append(stored)
                    }
                    return .completed(
                        output: output, artifactIDs: artifactIDs,
                        commitProposal: commitProposal, artifactMetadata: artifactMetadata,
                        executionEvidence: .init(
                            standardOutput: "Bounded agent completed \(turn + 1) model turn(s) and \(toolCalls) tool call(s).",
                            elapsedMilliseconds: Int64(Date().timeIntervalSince(started) * 1_000)
                        )
                    )
                case .tool:
                    guard toolCalls < policy.maximumToolCalls,
                          let capabilityID = action.capabilityID, let toolInput = action.input,
                          policy.allowedCapabilityIDs.contains(capabilityID),
                          capabilityID != "kaname.agent.bounded",
                          let installation = await MainActor.run(body: {
                              model.workflowCapabilityInstallation(capabilityID: capabilityID)
                          }), installation.enabled, installation.lastTestPassed,
                          !installation.permissions.broadens(callerRevision.permissions),
                          !installation.permissions.permissions.contains(where: {
                              [.externalEffects, .emailDraft, .emailSend, .emailLabels].contains($0)
                          }) else {
                        throw DesktopWorkflowCapabilityError.executionFailed("The bounded agent requested an unavailable or effect-capable tool.")
                    }
                    toolCalls += 1
                    let toolStep = DesktopWorkflowStepDefinition(
                        id: "\(invocation.step.id)-tool-\(toolCalls)", name: capabilityID,
                        kind: .invokeTool, capabilityID: capabilityID,
                        retryLimit: 0, isIdempotent: installation.idempotent, blocking: true
                    )
                    let result = try await router.invoke(
                        workflowID: invocation.workflowID, workItemID: invocation.workItemID,
                        episodeID: invocation.episodeID, runID: invocation.runID, step: toolStep,
                        contextSnapshotID: invocation.contextSnapshotID, input: toolInput,
                        artifactInputs: invocation.artifactInputs, stateInputs: invocation.stateInputs,
                        contextSnapshot: invocation.contextSnapshot,
                        installation: installation
                    )
                    guard case let .completed(toolOutput, toolArtifacts, toolCommit, toolMetadata, _) = result else {
                        throw DesktopWorkflowCapabilityError.executionFailed("A bounded-agent tool attempted to wait or create an effect.")
                    }
                    estimatedTokens += max(1, toolOutput.count / 4)
                    guard toolOutput.count <= 8 * 1_024 * 1_024 else {
                        throw DesktopWorkflowCapabilityError.outputInvalid
                    }
                    artifactIDs.append(contentsOf: toolArtifacts)
                    artifactMetadata.append(contentsOf: toolMetadata)
                    commitProposal.stateMutations.append(contentsOf: toolCommit.stateMutations)
                    commitProposal.knowledgeProposals.append(contentsOf: toolCommit.knowledgeProposals)
                    commitProposal.artifactRoles.append(contentsOf: toolCommit.artifactRoles)
                    transcript.append([
                        "role": "tool",
                        "content": "\(capabilityID): \(String(data: toolOutput, encoding: .utf8) ?? "[binary output \(toolOutput.count) bytes]")"
                    ])
                }
            }
            throw DesktopWorkflowCapabilityError.executionFailed("The bounded agent did not finish within its reviewed tool-call budget.")
        }
        for capabilityID in ["kaname.email.draft", "kaname.email.send"] {
            await router.register(capabilityID: capabilityID) { [weak model, weak self] invocation, _ in
                guard let model, let self else { throw DesktopWorkflowCapabilityError.executionUnavailable }
                let outbound = try WorkflowEmailEffectRequest.decode(invocation.input)
                let message = try outbound.message()
                let send = invocation.step.kind == .sendEmail
                let operation: MailOutboundOperation = send ? .send : .draft
                let readiness = try await self.mailAdapter.readiness(accountID: outbound.accountID)
                guard readiness.feature(send ? .send : .draft)?.ready == true else {
                    throw DesktopWorkflowCapabilityError.executionFailed("The requested outbound mail feature is not ready.")
                }
                let exactTarget = try await self.mailAdapter.exactOutboundTarget(
                    accountID: outbound.accountID, operation: operation, message: message
                )
                guard let storage = await MainActor.run(body: { model.workflowStorage(workflowID: invocation.workflowID) }) else {
                    throw DesktopWorkflowCapabilityError.executionFailed("Kaname could not open private workflow storage.")
                }
                let storedInput = try storage.importArtifact(
                    data: invocation.input,
                    filename: "email-effect-\(invocation.runID)-\(invocation.step.id).json",
                    mediaType: "application/json",
                    createdAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
                )
                guard await MainActor.run(body: {
                    model.proposeWorkflowEffect(
                        workItemID: invocation.workItemID,
                        episodeID: invocation.episodeID,
                        runID: invocation.runID,
                        stepID: invocation.step.id,
                        kind: send ? "mail-send" : "mail-draft",
                        accountID: outbound.accountID,
                        exactTarget: exactTarget,
                        contentDigest: storedInput.sha256,
                        attachmentDigests: outbound.attachments.map { DesktopWorkflowPackageCodec.digest($0.data) }
                    ) != nil
                }) else {
                    throw DesktopWorkflowCapabilityError.executionFailed("Kaname could not persist the exact email effect.")
                }
                return .waiting(reason: "Review and approve the exact email effect.")
            }
        }
        await router.register(capabilityID: "kaname.email.read") { [weak model, weak self] invocation, _ in
            guard let model, let self else { throw DesktopWorkflowCapabilityError.executionUnavailable }
            let request = try WorkflowEmailReadRequest.decode(invocation.input)
            guard await MainActor.run(body: {
                model.workflowRevision(runID: invocation.runID)?.permissions.accountIDs.contains(request.accountID) == true
            }) else { throw DesktopWorkflowCapabilityError.executionFailed("The mail account is outside this workflow revision's reviewed scope.") }
            let capturePolicy = await MainActor.run {
                model.workflowMailCapturePolicy(
                    workflowID: invocation.workflowID, accountID: request.accountID
                )
            }
            let readiness = try await self.mailAdapter.readiness(accountID: request.accountID)
            let requiredFeature: MailProviderFeature = switch request.operation {
            case .search: .boundedSearch
            case .thread: .conversationRead
            case .resources, .labels: .logicalResourceBinding
            }
            guard readiness.feature(requiredFeature)?.ready == true else {
                let missing = readiness.feature(requiredFeature)?.missingScopes.joined(separator: ", ") ?? "unsupported feature"
                throw DesktopWorkflowCapabilityError.executionFailed("The mail provider feature is not ready: \(missing).")
            }
            if let extensionID = request.queryExtensionID {
                guard readiness.feature(.boundedSearch)?.extensionIDs.contains(extensionID) == true else {
                    throw DesktopWorkflowCapabilityError.executionFailed("The mail adapter does not declare query extension \(extensionID).")
                }
            }
            if !request.headerProjection.isEmpty {
                guard let extensionID = request.headerProjectionExtensionID,
                      readiness.feature(.conversationRead)?.extensionIDs.contains(extensionID) == true else {
                    throw DesktopWorkflowCapabilityError.executionFailed("The mail adapter does not declare projected-header support.")
                }
            }
            var conversations: [MailConversationSnapshot] = []
            var resources: [MailResourceSnapshot] = []
            var pages = 0
            switch request.operation {
            case .search:
                var pageToken: String?
                var seenTokens = Set<String>()
                repeat {
                    guard pages < request.maximumPages else {
                        throw DesktopWorkflowCapabilityError.executionFailed("The mail search exceeded its reviewed page limit.")
                    }
                    let extensions = request.queryExtensionID.map { [$0: request.query ?? ""] } ?? [:]
                    let page = try await self.mailAdapter.search(
                        accountID: request.accountID,
                        query: MailQuery(
                            text: request.query ?? "", pageToken: pageToken, limit: 100, extensions: extensions
                        )
                    )
                    guard page.failedConversationCount == 0 else {
                        throw DesktopWorkflowCapabilityError.executionFailed("The mail provider returned an incomplete conversation page.")
                    }
                    conversations.append(contentsOf: page.conversations)
                    guard conversations.count <= request.maximumThreads else {
                        throw DesktopWorkflowCapabilityError.executionFailed("The mail search exceeded its reviewed conversation limit.")
                    }
                    pages += 1
                    pageToken = page.nextPageToken
                    if let pageToken, !seenTokens.insert(pageToken).inserted {
                        throw DesktopWorkflowCapabilityError.executionFailed("The mail provider repeated a search page token.")
                    }
                } while pageToken != nil
            case .thread:
                conversations = [try await self.mailAdapter.conversation(
                    accountID: request.accountID, conversationID: request.threadID ?? ""
                )]
                pages = 1
            case .resources, .labels:
                resources = try await self.mailAdapter.resources(accountID: request.accountID)
                pages = 1
            }
            var attachments: [String: Data] = [:]
            if request.includeAttachmentBytes, capturePolicy.includeAttachments {
                var total = 0
                var count = 0
                for conversation in conversations {
                    for message in conversation.messages {
                        for attachment in message.attachments {
                            guard let policyMaximum = capturePolicy.maximumBytesForNextAttachment(
                                mediaType: attachment.mediaType, declaredSize: attachment.size,
                                capturedCount: count, capturedBytes: total
                            ) else { continue }
                            let maximumBytes = min(request.maximumAttachmentBytes, policyMaximum)
                            guard attachment.size <= maximumBytes else { continue }
                            let data = try await self.mailAdapter.attachment(
                                accountID: request.accountID, messageID: attachment.messageID,
                                attachmentID: attachment.attachmentID,
                                maximumBytes: maximumBytes
                            )
                            total += data.count
                            guard total <= capturePolicy.maximumTotalBytes else {
                                throw DesktopWorkflowCapabilityError.inputTooLarge
                            }
                            attachments[WorkflowEmailReadResponse.attachmentKey(attachment)] = data
                            count += 1
                        }
                    }
                }
            }
            let output = try WorkflowEmailReadResponse.encode(
                request: request, conversations: conversations, resources: resources, pages: pages,
                attachmentPayloads: attachments, capturePolicy: capturePolicy
            )
            return .completed(output: output, artifactIDs: [])
        }
        await router.register(capabilityID: "kaname.connector.effect") { [weak model, weak effectCoordinator] invocation, _ in
            guard let model, let effectCoordinator else { throw DesktopWorkflowCapabilityError.executionUnavailable }
            let input = try WorkflowConnectorEffectInput.decode(invocation.input)
            guard let revision = await MainActor.run(body: { model.workflowRevision(runID: invocation.runID) }),
                  revision.permissions.permissions.contains(.externalEffects),
                  input.accountID.map(revision.permissions.accountIDs.contains) ?? true else {
                throw DesktopWorkflowCapabilityError.executionFailed("The connector effect is outside this workflow revision's reviewed authority.")
            }
            _ = try await effectCoordinator.preview(input.request(for: invocation))
            return .waiting(reason: "Review or apply the exact trusted connector effect.")
        }
        return DesktopWorkflowRuntime(
            model: model,
            invoker: router,
            workflowInstallationsRoot: environment.applicationSupportRoot
                .appendingPathComponent("WorkflowInstallations", isDirectory: true)
        )
    }

    public func requestWorkflowEffectApproval(model: DesktopAppModel, effect: DesktopWorkflowEffectRecord) {
        let preview = model.snapshot.operations.workflows.effectPreviews.first(where: { $0.effectID == effect.id })
        guard effect.approvalID == nil,
              let approvalID = model.createApproval(
                  threadID: nil,
                  title: preview?.title ?? (effect.kind == "mail-send" ? "Send workflow email" : "Create workflow email draft"),
                  exactTarget: effect.exactTarget,
                  consequence: preview?.consequences.joined(separator: " ") ?? (effect.kind == "mail-send"
                      ? "Send the exact reviewed workflow reply."
                      : "Create the exact reviewed workflow draft at the selected provider."),
                  dataLeavingDevice: effect.kind.hasPrefix("mail-")
                      ? "Recipients, thread headers, subject, body, and attachment bytes"
                      : "Exact connector target and declared effect payload",
                  reversible: preview?.reversible ?? (effect.kind != "mail-send"),
                  expiresAtUnixMillis: Int64(Date().addingTimeInterval(15 * 60).timeIntervalSince1970 * 1_000)
              ) else { return }
        _ = model.attachWorkflowEffectApproval(effectID: effect.id, approvalID: approvalID)
        message = "The exact workflow email effect is ready in Inbox."
    }

    public func executeWorkflowEffect(model: DesktopAppModel, effect: DesktopWorkflowEffectRecord) {
        if model.snapshot.operations.workflows.effectPreviews.contains(where: {
            $0.effectID == effect.id && $0.connectorID == "kaname.mail"
        }) {
            executeTrustedConnectorEffect(model: model, effect: effect)
            return
        }
        guard !isBusy,
              effect.state == .approved || effect.state == .awaitingApproval,
              model.beginWorkflowEffect(effectID: effect.id),
              let item = model.workflowWorkItems.first(where: { $0.id == effect.workItemID }),
              let storage = model.workflowStorage(workflowID: item.workflowID),
              let input = try? storage.artifactData(sha256: effect.contentDigest),
              let request = try? WorkflowEmailEffectRequest.decode(input),
              let outbound = try? request.message(),
              let approvalID = effect.approvalID else {
            message = "Approve this exact workflow effect in Inbox first."
            return
        }
        isBusy = true
        _Concurrency.Task {
            do {
                let operation: MailOutboundOperation = effect.kind == "mail-send" ? .send : .draft
                let outboundReceipt = try await mailAdapter.performOutbound(
                    accountID: request.accountID, operation: operation, message: outbound,
                    grant: MailEffectGrant(approvalID: approvalID, exactTarget: effect.exactTarget)
                )
                let reconciliation = outboundReceipt.reconciliation
                let receipt = "\(operation == .send ? "Sent message" : "Draft") \(outboundReceipt.remoteID). Verified recipients, subject, conversation, and \(reconciliation.attachmentNames.count) attachment(s) at \(mailAdapter.identity.displayName)."
                _ = model.reconcileWorkflowEffect(
                    effectID: effect.id, receipt: receipt, outcomeKnown: true, succeeded: true
                )
                let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
                _ = model.resumeWorkflowStepAfterEffect(runID: effect.runID, stepID: effect.stepID, outputDigest: digest)
                message = receipt
                await executeQueuedWorkflowRuns(model: model)
            } catch MailProviderAdapterError.reconciliationFailed {
                _ = model.reconcileWorkflowEffect(
                    effectID: effect.id,
                    receipt: MailProviderAdapterError.reconciliationFailed.localizedDescription,
                    outcomeKnown: true,
                    succeeded: false
                )
                message = "The mail provider returned a result that did not match the approved message. Kaname will not retry it."
            } catch {
                _ = model.reconcileWorkflowEffect(
                    effectID: effect.id,
                    receipt: error.localizedDescription,
                    outcomeKnown: false,
                    succeeded: false
                )
                message = "The mail-provider outcome is unknown. Kaname will not retry until it is reconciled."
            }
            isBusy = false
        }
    }

    private func executeTrustedConnectorEffect(model: DesktopAppModel, effect: DesktopWorkflowEffectRecord) {
        guard !isBusy, let workflowEffectCoordinator else {
            message = "The trusted connector is unavailable."
            return
        }
        isBusy = true
        _Concurrency.Task {
            do {
                let receipt = try await (effect.state == .outcomeUnknown
                    ? workflowEffectCoordinator.reconcile(effectID: effect.id)
                    : workflowEffectCoordinator.execute(effectID: effect.id))
                guard receipt.outcomeKnown, receipt.succeeded else {
                    message = receipt.detail
                    isBusy = false
                    return
                }
                let digest = DesktopWorkflowPackageCodec.digest(Data(receipt.detail.utf8))
                _ = model.resumeWorkflowStepAfterEffect(
                    runID: effect.runID, stepID: effect.stepID, outputDigest: digest
                )
                message = receipt.detail
                await executeQueuedWorkflowRuns(model: model)
            } catch {
                message = error.localizedDescription
            }
            isBusy = false
        }
    }

    public func completeWorkflowHumanReview(model: DesktopAppModel, runID: String, stepID: String) {
        let digest = SHA256.hash(data: Data("human-review:\(runID):\(stepID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard model.resumeWorkflowStepAfterEffect(runID: runID, stepID: stepID, outputDigest: digest) else {
            message = "This review stage is no longer waiting."
            return
        }
        message = "Review recorded. The workflow can continue."
        _Concurrency.Task { await executeQueuedWorkflowRuns(model: model) }
    }

    public func search(accounts: [NativeGoogleAccountSnapshot], model: DesktopAppModel, loadMore: Bool = false) {
        guard !isBusy, !accounts.isEmpty else { return }
        isBusy = true
        if !loadMore {
            threads = []
            nextPageTokens = [:]
        }
        failedAccounts = []
        Task {
            var discovered: [GmailThreadDetailSnapshot] = []
            var tokens = nextPageTokens
            var failures: [String] = []
            var failedThreads = 0
            for account in accounts {
                do {
                    let page = try await service.searchMail(
                        accountID: account.id,
                        query: query,
                        pageToken: loadMore ? tokens[account.id] : nil
                    )
                    discovered.append(contentsOf: page.threads)
                    failedThreads += page.failedThreadCount
                    tokens[account.id] = page.nextPageToken
                    if page.nextPageToken == nil { tokens.removeValue(forKey: account.id) }
                } catch {
                    failures.append(account.identity)
                }
            }
            threads = Self.deduplicated(loadMore ? threads + discovered : discovered)
            nextPageTokens = tokens
            failedAccounts = failures
            reconcileAttention(model: model)
            message = failures.isEmpty && failedThreads == 0
                ? "Loaded \(discovered.count) thread(s) across \(accounts.count) account(s)."
                : "Loaded \(discovered.count) thread(s); \(failedThreads) thread detail(s) and \(failures.count) account(s) could not reconcile."
            isBusy = false
        }
    }

    @discardableResult
    public func select(_ thread: GmailThreadDetailSnapshot, model: DesktopAppModel) -> GmailThreadMutation? {
        selectedThread = thread
        activeActionID = nil
        localSummary = nil
        return restoreThreadAction(model: model, thread: thread)
    }

    public func summarize(_ thread: GmailThreadDetailSnapshot) {
        let participants = Array(Set(thread.messages.map(\.sender).filter { !$0.isEmpty })).sorted()
        let latest = thread.messages.last?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? thread.snippet
        let bounded = String(latest.prefix(600))
        localSummary = "\(thread.messages.count) message(s) involving \(participants.joined(separator: ", ")). Latest content: \(bounded)"
    }

    public func refreshSelected(model: DesktopAppModel) {
        guard !isBusy, let selectedThread else { return }
        isBusy = true
        Task {
            do {
                let refreshed = try await service.readMailThread(
                    accountID: selectedThread.accountID,
                    threadID: selectedThread.id
                )
                replaceThread(refreshed)
                self.selectedThread = refreshed
                reconcileAttention(model: model)
                message = "Reconciled the current Gmail thread."
            } catch { message = error.localizedDescription }
            isBusy = false
        }
    }

    public func loadLabels(accountID: String) {
        Task {
            do { labels[accountID] = try await service.listGmailLabels(accountID: accountID) }
            catch { message = error.localizedDescription }
        }
    }

    public func proposeThreadMutation(
        model: DesktopAppModel,
        thread: GmailThreadDetailSnapshot,
        mutation: GmailThreadMutation,
        preview: String,
        kind: DesktopMailActionRecord.Kind,
        standingRuleID: String? = nil
    ) {
        let target = NativeGoogleIntegrationService.gmailMutationTarget(
            accountID: thread.accountID,
            threadID: thread.id,
            mutation: mutation
        )
        if let existing = model.resumableMailAction(
            accountID: thread.accountID,
            threadID: thread.id,
            exactTarget: target
        ), existing.kind == kind {
            activeActionID = existing.id
            message = actionResumeMessage(existing, model: model)
            return
        }
        activeActionID = model.recordMailAction(
            accountID: thread.accountID,
            accountIdentity: thread.accountIdentity,
            threadID: thread.id,
            kind: kind,
            preview: preview,
            exactTarget: target,
            standingRuleID: standingRuleID
        )
        message = standingRuleID == nil ? "Review the exact action before requesting approval." : "Standing-rule action is ready to run and reconcile."
    }

    public func requestActiveApproval(model: DesktopAppModel) {
        guard let action = activeAction(model: model), action.approvalID == nil else { return }
        guard let approvalID = model.createApproval(
            threadID: nil,
            title: action.kind.label,
            exactTarget: action.exactTarget,
            consequence: action.preview,
            dataLeavingDevice: action.kind == .send ? "Recipients, subject, and resolved message body" : "Account, thread, and label identifiers",
            reversible: action.kind != .send,
            expiresAtUnixMillis: nil
        ) else { return }
        model.attachMailApproval(actionID: action.id, approvalID: approvalID)
        message = "This exact Gmail action is ready in Inbox."
    }

    public func executeActiveThreadMutation(model: DesktopAppModel, mutation: GmailThreadMutation) {
        guard !isBusy, let action = authorizedAction(model: model), let threadID = action.threadID else {
            message = "Approve this exact action in Inbox first."
            return
        }
        isBusy = true
        Task {
            do {
                let receipt = try await service.mutateMailThread(
                    accountID: action.accountID,
                    threadID: threadID,
                    mutation: mutation,
                    grant: GmailMutationGrant(
                        approvalID: action.approvalID ?? "standing-rule:\(action.standingRuleID ?? "")",
                        exactTarget: action.exactTarget
                    )
                )
                replaceThread(receipt.reconciledThread)
                selectedThread = receipt.reconciledThread
                model.reconcileMailAction(
                    id: action.id,
                    state: .reconciled,
                    remoteReceipt: "Gmail labels reconciled: \(receipt.reconciledThread.labels.joined(separator: ", "))"
                )
                reconcileAttention(model: model)
                message = "Gmail confirmed the action remotely."
            } catch {
                model.reconcileMailAction(id: action.id, state: .failed, remoteReceipt: error.localizedDescription)
                message = error.localizedDescription
            }
            isBusy = false
        }
    }

    public func proposeOutbound(model: DesktopAppModel, draft: DesktopEmailDraft, account: NativeGoogleAccountSnapshot, send: Bool) {
        let outbound = GmailOutboundMessage(recipients: draft.recipients, subject: draft.subject, body: draft.body)
        do {
            let target = try send
                ? NativeGoogleIntegrationService.gmailSendTarget(accountID: account.id, message: outbound)
                : NativeGoogleIntegrationService.gmailDraftTarget(accountID: account.id, message: outbound)
            activeActionID = model.recordMailAction(
                accountID: account.id,
                accountIdentity: account.identity,
                threadID: nil,
                kind: send ? .send : .createDraft,
                preview: send
                    ? "Send “\(draft.subject)” from \(account.identity) to \(draft.recipients)."
                    : "Create a Gmail draft “\(draft.subject)” in \(account.identity).",
                exactTarget: target
            )
            message = "Review the resolved account, recipients, subject, and body before approval."
        } catch { message = error.localizedDescription }
    }

    public func executeOutbound(model: DesktopAppModel, draft: DesktopEmailDraft, send: Bool) {
        guard !isBusy, let action = authorizedAction(model: model) else {
            message = "Approve this exact outbound message in Inbox first."
            return
        }
        let outbound = GmailOutboundMessage(recipients: draft.recipients, subject: draft.subject, body: draft.body)
        isBusy = true
        Task {
            do {
                let grant = GmailMutationGrant(approvalID: action.approvalID ?? "", exactTarget: action.exactTarget)
                let remoteReceipt: String
                if send {
                    let receipt = try await service.sendGmailMessage(accountID: action.accountID, message: outbound, grant: grant)
                    remoteReceipt = "Sent message \(receipt.messageID). \(receipt.reconciliation.summary)"
                } else {
                    let receipt = try await service.createGmailDraft(accountID: action.accountID, message: outbound, grant: grant)
                    remoteReceipt = "Draft \(receipt.id). \(receipt.reconciliation.summary)"
                }
                model.markEmailDraft(id: draft.id, status: send ? .ready : .proposed)
                model.reconcileMailAction(id: action.id, state: .reconciled, remoteReceipt: remoteReceipt)
                message = remoteReceipt
            } catch {
                model.reconcileMailAction(id: action.id, state: .failed, remoteReceipt: error.localizedDescription)
                message = error.localizedDescription
            }
            isBusy = false
        }
    }

    public func saveAttachment(accountID: String, attachment: GmailAttachmentSnapshot) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.message = "Save this attachment after downloading it from the selected Gmail account."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isBusy = true
        Task {
            do {
                let data = try await service.downloadGmailAttachment(
                    accountID: accountID,
                    messageID: attachment.messageID,
                    attachmentID: attachment.attachmentID
                )
                try data.write(to: destination, options: .atomic)
                message = "Saved \(attachment.filename)."
            } catch { message = error.localizedDescription }
            isBusy = false
        }
    }

    public func createStandingRule(
        model: DesktopAppModel,
        account: NativeGoogleAccountSnapshot,
        name: String,
        action: DesktopMailActionRecord.Kind
    ) {
        guard model.createMailStandingRule(
            accountID: account.id,
            accountIdentity: account.identity,
            name: name,
            query: query,
            action: action
        ) != nil else {
            message = "Standing rules are limited to explicit archive or label actions."
            return
        }
        message = "Standing rule saved visibly for \(account.identity); it can be paused at any time."
    }

    public func runStandingRule(model: DesktopAppModel, rule: DesktopMailStandingRule) {
        guard !isBusy, rule.enabled else {
            message = rule.enabled ? "Another Gmail operation is still running." : "Enable this rule before running it."
            return
        }
        guard rule.action == .archive else {
            message = "This rule needs label details before it can run. Edit or replace it with an archive rule."
            return
        }
        isBusy = true
        Task {
            var pageToken: String?
            var processed = 0
            var failures = 0
            var pages = 0
            repeat {
                do {
                    let page = try await service.searchMail(
                        accountID: rule.accountID,
                        query: rule.query,
                        pageToken: pageToken
                    )
                    failures += page.failedThreadCount
                    for thread in page.threads {
                        let mutation = GmailThreadMutation.archive
                        let target = NativeGoogleIntegrationService.gmailMutationTarget(
                            accountID: rule.accountID,
                            threadID: thread.id,
                            mutation: mutation
                        )
                        guard let actionID = model.recordMailAction(
                            accountID: rule.accountID,
                            accountIdentity: rule.accountIdentity,
                            threadID: thread.id,
                            kind: .archive,
                            preview: "Archive “\(thread.messages.last?.subject ?? "(No subject)")” from the saved query “\(rule.query)”.",
                            exactTarget: target,
                            standingRuleID: rule.id
                        ) else {
                            failures += 1
                            continue
                        }
                        activeActionID = actionID
                        do {
                            let receipt = try await service.mutateMailThread(
                                accountID: rule.accountID,
                                threadID: thread.id,
                                mutation: mutation,
                                grant: GmailMutationGrant(
                                    approvalID: "standing-rule:\(rule.id)",
                                    exactTarget: target
                                )
                            )
                            model.reconcileMailAction(
                                id: actionID,
                                state: .reconciled,
                                remoteReceipt: "Gmail removed INBOX and the thread was re-read."
                            )
                            replaceThread(receipt.reconciledThread)
                            processed += 1
                        } catch {
                            model.reconcileMailAction(id: actionID, state: .failed, remoteReceipt: error.localizedDescription)
                            failures += 1
                        }
                    }
                    pageToken = page.nextPageToken
                    pages += 1
                } catch {
                    failures += 1
                    pageToken = nil
                }
            } while pageToken != nil && pages < 20
            reconcileAttention(model: model)
            if pageToken != nil {
                message = "Archived \(processed) thread(s); stopped after 20 pages so this rule remains bounded. Run it again to continue."
            } else if failures > 0 {
                message = "Archived \(processed) thread(s); \(failures) item(s) could not be reconciled. Successful actions remain recorded."
            } else {
                message = "Archived and remotely reconciled \(processed) thread(s) under “\(rule.name)”."
            }
            isBusy = false
        }
    }

    private func activeAction(model: DesktopAppModel) -> DesktopMailActionRecord? {
        activeActionID.flatMap { id in model.snapshot.operations.mailActions.first { $0.id == id } }
    }

    private func restoreThreadAction(
        model: DesktopAppModel,
        thread: GmailThreadDetailSnapshot
    ) -> GmailThreadMutation? {
        let candidates: [(mutation: GmailThreadMutation, action: DesktopMailActionRecord)] = [
            (GmailThreadMutation.archive, DesktopMailActionRecord.Kind.archive),
            (GmailThreadMutation.trash, DesktopMailActionRecord.Kind.trash),
        ].compactMap { mutation, kind in
            let target = NativeGoogleIntegrationService.gmailMutationTarget(
                accountID: thread.accountID,
                threadID: thread.id,
                mutation: mutation
            )
            guard let action = model.resumableMailAction(
                accountID: thread.accountID,
                threadID: thread.id,
                exactTarget: target
            ), action.kind == kind else { return nil }
            return (mutation, action)
        }
        guard let restored = candidates.max(by: {
            $0.action.createdAtUnixMillis < $1.action.createdAtUnixMillis
        }) else { return nil }
        activeActionID = restored.action.id
        message = actionResumeMessage(restored.action, model: model)
        return restored.mutation
    }

    private func actionResumeMessage(
        _ action: DesktopMailActionRecord,
        model: DesktopAppModel
    ) -> String {
        guard let approvalID = action.approvalID,
              let approval = model.snapshot.operations.approvals.first(where: { $0.id == approvalID }) else {
            return "Restored the exact proposed Gmail action for review."
        }
        return approval.state == .approved
            ? "Restored the exact approved Gmail action. Apply it here when ready."
            : "Restored the exact Gmail action waiting in Inbox."
    }

    private func authorizedAction(model: DesktopAppModel) -> DesktopMailActionRecord? {
        guard let action = activeAction(model: model) else { return nil }
        if action.standingRuleID != nil { return action }
        guard action.state == .awaitingApproval,
              let approvalID = action.approvalID,
              let approval = model.snapshot.operations.approvals.first(where: { $0.id == approvalID }),
              approval.state == .approved,
              approval.exactTarget == action.exactTarget else { return nil }
        return action
    }

    private func replaceThread(_ thread: GmailThreadDetailSnapshot) {
        threads.removeAll { $0.accountID == thread.accountID && $0.id == thread.id }
        threads.append(thread)
    }

    private func reconcileAttention(model: DesktopAppModel) {
        model.reconcileMailAttention(threads.compactMap { thread in
            guard let message = thread.messages.last else { return nil }
            return (
                accountID: thread.accountID,
                threadID: thread.id,
                accountIdentity: thread.accountIdentity,
                sender: message.sender,
                subject: message.subject,
                unread: thread.labels.contains("UNREAD")
            )
        })
    }

    private static func deduplicated(_ threads: [GmailThreadDetailSnapshot]) -> [GmailThreadDetailSnapshot] {
        Dictionary(grouping: threads, by: { "\($0.accountID):\($0.id)" })
            .compactMap { $0.value.last }
            .sorted { ($0.messages.last?.dateDescription ?? "") > ($1.messages.last?.dateDescription ?? "") }
    }
}
