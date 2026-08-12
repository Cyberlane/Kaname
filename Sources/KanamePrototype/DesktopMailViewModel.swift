import AppKit
import CryptoKit
import Foundation
import KanameConnectivity
import KanameDesktop

@MainActor
final class DesktopMailViewModel: ObservableObject {
    @Published private(set) var threads: [GmailThreadDetailSnapshot] = []
    @Published private(set) var selectedThread: GmailThreadDetailSnapshot?
    @Published private(set) var labels: [String: [GmailLabelSnapshot]] = [:]
    @Published private(set) var nextPageTokens: [String: String] = [:]
    @Published private(set) var failedAccounts: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var activeActionID: String?
    @Published private(set) var localSummary: String?
    @Published var query = "in:inbox"

    private let service: NativeGoogleIntegrationService
    private let environment: KanameDesktopEnvironment
    private var workflowMonitoringTask: _Concurrency.Task<Void, Never>?
    private var workflowRuntime: DesktopWorkflowRuntime?

    init(environment: KanameDesktopEnvironment = .current) {
        self.environment = environment
        service = NativeGoogleIntegrationService(
            rootDirectory: environment.googleDirectory,
            keychainService: environment.googleKeychainService
        )
    }

    func startWorkflowMonitoring(model: DesktopAppModel) {
        guard workflowMonitoringTask == nil,
              !CommandLine.arguments.contains("--snapshot") else { return }
        workflowMonitoringTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            _ = model.recoverExpiredWorkflowClaims()
            await pollWorkflowBindings(model: model, announce: false)
            await executeQueuedWorkflowRuns(model: model)
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .seconds(300))
                guard !_Concurrency.Task.isCancelled else { return }
                await pollWorkflowBindings(model: model, announce: false)
                await executeQueuedWorkflowRuns(model: model)
            }
        }
    }

    func checkWorkflowTriggers(model: DesktopAppModel) {
        _Concurrency.Task { await pollWorkflowBindings(model: model, announce: true) }
    }

    private func pollWorkflowBindings(model: DesktopAppModel, announce: Bool) async {
        let definitions = Dictionary(uniqueKeysWithValues: model.workflowDefinitions.map { ($0.id, $0) })
        let bindings = model.workflowTriggerBindings().filter {
            $0.enabled && $0.trigger == .email && $0.source == "gmail" && definitions[$0.workflowID]?.enabled == true
        }
        guard !bindings.isEmpty else { return }
        var observedEpisodes = 0
        var failures: [String] = []
        for binding in bindings {
            for accountID in binding.accountIDs {
                do {
                    guard let cursor = binding.lastCursor else {
                        _ = model.advanceWorkflowTriggerCursor(
                            id: binding.id,
                            cursor: try await service.gmailHistoryCursor(accountID: accountID)
                        )
                        continue
                    }
                    let matching = try await service.matchingGmailThreadIDs(
                        accountID: accountID,
                        query: binding.sourceFilter
                    )
                    let observation = try await GmailHistoryObserver(service: service).observe(
                        accountID: accountID,
                        startHistoryID: cursor,
                        historyTypes: [.messageAdded]
                    )
                    switch observation {
                    case let .events(events, nextCursor):
                        for event in events where matching.contains(event.threadID) {
                            let thread = try await service.readMailThread(accountID: accountID, threadID: event.threadID)
                            if try await ingestWorkflowThread(
                                thread,
                                event: event,
                                binding: binding,
                                cursor: nextCursor,
                                model: model
                            ) { observedEpisodes += 1 }
                        }
                        _ = model.advanceWorkflowTriggerCursor(id: binding.id, cursor: nextCursor)
                    case .fullSyncRequired:
                        for threadID in matching.sorted() {
                            let thread = try await service.readMailThread(accountID: accountID, threadID: threadID)
                            guard let latest = thread.messages.last else { continue }
                            let event = GmailHistoryEvent.record(
                                id: "full-sync:\(accountID):\(latest.id)",
                                historyID: thread.historyID ?? cursor,
                                kind: .messageAdded,
                                messageID: latest.id,
                                threadID: thread.id,
                                labelIDs: latest.labels
                            )
                            if try await ingestWorkflowThread(
                                thread,
                                event: event,
                                binding: binding,
                                cursor: thread.historyID ?? cursor,
                                model: model
                            ) { observedEpisodes += 1 }
                        }
                        _ = model.advanceWorkflowTriggerCursor(
                            id: binding.id,
                            cursor: try await service.gmailHistoryCursor(accountID: accountID)
                        )
                    }
                } catch {
                    failures.append("\(binding.workflowID): \(error.localizedDescription)")
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

    private func ingestWorkflowThread(
        _ thread: GmailThreadDetailSnapshot,
        event: GmailHistoryEvent,
        binding: DesktopWorkflowTriggerBindingRecord,
        cursor: String,
        model: DesktopAppModel
    ) async throws -> Bool {
        guard let message = thread.messages.first(where: { $0.id == event.messageID }) ?? thread.messages.last else { return false }
        var attachmentPayloads: [String: Data] = [:]
        var totalAttachmentBytes = 0
        for attachment in message.attachments {
            let data = try await service.downloadGmailAttachment(
                accountID: thread.accountID,
                messageID: attachment.messageID,
                attachmentID: attachment.attachmentID
            )
            totalAttachmentBytes += data.count
            guard totalAttachmentBytes <= GmailOutboundAttachment.maximumTotalBytes else {
                throw DesktopWorkflowStorageError.quotaExceeded
            }
            attachmentPayloads[attachment.attachmentID] = data
        }
        let payload = try workflowEventPayload(
            thread: thread,
            message: message,
            attachmentPayloads: attachmentPayloads
        )
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let eventID = model.observeWorkflowExternalEvent(
            source: "gmail",
            accountID: thread.accountID,
            conversationID: thread.id,
            messageID: message.id,
            cursor: cursor,
            payloadDigest: digest,
            deduplicationKey: "gmail:\(thread.accountID):\(message.id)"
        )
        guard let eventID else { return false }
        if model.snapshot.operations.workflows.episodes.contains(where: { $0.sourceEventID == eventID }) { return false }

        var item = model.workflowWorkItems(accountID: thread.accountID, conversationID: thread.id)
            .first(where: { $0.workflowID == binding.workflowID })
        if item == nil,
           let workItemID = model.createWorkflowWorkItem(
               workflowID: binding.workflowID,
               title: message.subject.isEmpty ? "Email workflow" : message.subject,
               goal: "Handle this account-scoped email conversation under the installed workflow contract."
           ) {
            _ = model.bindWorkflowConversation(
                workItemID: workItemID,
                source: "gmail",
                accountID: thread.accountID,
                conversationID: thread.id,
                relationship: .primary,
                reason: "Matched the reviewed Gmail trigger filter.",
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
               filename: "gmail-event-\(message.id).json",
               mediaType: "application/json",
               createdAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
           ) {
            artifactDigest = artifact.sha256
        }
        let contextID = model.compileWorkflowContext(
            workItemID: item.id,
            episodeID: episodeID,
            request: message.body.isEmpty ? message.subject : message.body,
            references: [
                .reference(
                    id: eventID,
                    kind: "gmail-message",
                    label: message.subject.isEmpty ? "Gmail message" : message.subject,
                    sourceID: "gmail:\(thread.accountID):\(message.id)",
                    digest: artifactDigest,
                    included: true,
                    reason: "Triggered the active workflow episode.",
                    estimatedTokens: max(1, min(message.body.count / 4, 16_000))
                )
            ]
        )
        if let contextID {
            _ = model.queueWorkflowRun(workItemID: item.id, episodeID: episodeID, contextSnapshotID: contextID)
        }
        return true
    }

    private func workflowEventPayload(
        thread: GmailThreadDetailSnapshot,
        message: GmailMessageSnapshot,
        attachmentPayloads: [String: Data]
    ) throws -> Data {
        let object: [String: Any] = [
            "accountID": thread.accountID,
            "accountIdentity": thread.accountIdentity,
            "threadID": thread.id,
            "historyID": thread.historyID ?? "",
            "message": [
                "id": message.id,
                "sender": message.sender,
                "recipients": message.recipients,
                "subject": message.subject,
                "date": message.dateDescription,
                "body": message.body,
                "labels": message.labels,
                "attachments": message.attachments.map {
                    [
                        "id": $0.attachmentID,
                        "filename": $0.filename,
                        "mediaType": $0.mimeType,
                        "size": $0.size,
                        "dataBase64": attachmentPayloads[$0.attachmentID]?.base64EncodedString() ?? "",
                    ] as [String: Any]
                },
            ] as [String: Any],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
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
            let service = NativeProviderDiscussionService()
            let provider = try request.provider
            let providerText: String
            switch provider {
            case .codex:
                providerText = try await service.runCodex(
                    prompt: request.prompt,
                    workspace: workflowModelWorkspace,
                    executable: nil
                )
            case let .native(driver):
                providerText = try await service.run(
                    driver: driver,
                    prompt: request.prompt,
                    workspace: workflowModelWorkspace
                ).text
            }
            let output = try request.validatedOutput(providerText)
            return .completed(output: output, artifactIDs: [])
        }
        for capabilityID in ["kaname.email.draft", "kaname.email.send"] {
            await router.register(capabilityID: capabilityID) { [weak model] invocation, _ in
                guard let model else { throw DesktopWorkflowCapabilityError.executionUnavailable }
                let outbound = try WorkflowEmailEffectRequest.decode(invocation.input)
                let message = try outbound.message()
                let send = invocation.step.kind == .sendEmail
                let exactTarget = try send
                    ? NativeGoogleIntegrationService.gmailSendTarget(accountID: outbound.accountID, message: message)
                    : NativeGoogleIntegrationService.gmailDraftTarget(accountID: outbound.accountID, message: message)
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
                        kind: send ? "gmail-send" : "gmail-draft",
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
        await router.register(capabilityID: "kaname.email.read") { invocation, _ in
            .completed(output: invocation.input, artifactIDs: [])
        }
        return DesktopWorkflowRuntime(
            model: model,
            invoker: router,
            workflowInstallationsRoot: environment.applicationSupportRoot
                .appendingPathComponent("WorkflowInstallations", isDirectory: true)
        )
    }

    func requestWorkflowEffectApproval(model: DesktopAppModel, effect: DesktopWorkflowEffectRecord) {
        guard effect.approvalID == nil,
              let approvalID = model.createApproval(
                  threadID: nil,
                  title: effect.kind == "gmail-send" ? "Send workflow email" : "Create workflow Gmail draft",
                  exactTarget: effect.exactTarget,
                  consequence: effect.kind == "gmail-send"
                      ? "Send the exact reviewed workflow reply."
                      : "Create the exact reviewed workflow draft in Gmail.",
                  dataLeavingDevice: "Recipients, thread headers, subject, body, and attachment bytes",
                  reversible: effect.kind != "gmail-send",
                  expiresAtUnixMillis: Int64(Date().addingTimeInterval(15 * 60).timeIntervalSince1970 * 1_000)
              ) else { return }
        _ = model.attachWorkflowEffectApproval(effectID: effect.id, approvalID: approvalID)
        message = "The exact workflow email effect is ready in Inbox."
    }

    func executeWorkflowEffect(model: DesktopAppModel, effect: DesktopWorkflowEffectRecord) {
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
                let grant = GmailMutationGrant(approvalID: approvalID, exactTarget: effect.exactTarget)
                let receipt: String
                if effect.kind == "gmail-send" {
                    let sent = try await service.sendGmailMessage(accountID: request.accountID, message: outbound, grant: grant)
                    receipt = "Sent message \(sent.messageID) was re-read from Gmail."
                } else {
                    let drafted = try await service.createGmailDraft(accountID: request.accountID, message: outbound, grant: grant)
                    receipt = "Draft \(drafted.id) was re-read from Gmail."
                }
                _ = model.reconcileWorkflowEffect(effectID: effect.id, receipt: receipt, outcomeKnown: true, succeeded: true)
                let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
                _ = model.resumeWorkflowStepAfterEffect(runID: effect.runID, stepID: effect.stepID, outputDigest: digest)
                message = receipt
                await executeQueuedWorkflowRuns(model: model)
            } catch {
                _ = model.reconcileWorkflowEffect(
                    effectID: effect.id,
                    receipt: error.localizedDescription,
                    outcomeKnown: false,
                    succeeded: false
                )
                message = "The Gmail outcome is unknown. Kaname will not retry until it is reconciled."
            }
            isBusy = false
        }
    }

    func completeWorkflowHumanReview(model: DesktopAppModel, runID: String, stepID: String) {
        let digest = SHA256.hash(data: Data("human-review:\(runID):\(stepID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard model.resumeWorkflowStepAfterEffect(runID: runID, stepID: stepID, outputDigest: digest) else {
            message = "This review stage is no longer waiting."
            return
        }
        message = "Review recorded. The workflow can continue."
        _Concurrency.Task { await executeQueuedWorkflowRuns(model: model) }
    }

    func search(accounts: [NativeGoogleAccountSnapshot], model: DesktopAppModel, loadMore: Bool = false) {
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

    func select(_ thread: GmailThreadDetailSnapshot) {
        selectedThread = thread
        activeActionID = nil
        localSummary = nil
    }

    func summarize(_ thread: GmailThreadDetailSnapshot) {
        let participants = Array(Set(thread.messages.map(\.sender).filter { !$0.isEmpty })).sorted()
        let latest = thread.messages.last?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? thread.snippet
        let bounded = String(latest.prefix(600))
        localSummary = "\(thread.messages.count) message(s) involving \(participants.joined(separator: ", ")). Latest content: \(bounded)"
    }

    func refreshSelected(model: DesktopAppModel) {
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

    func loadLabels(accountID: String) {
        Task {
            do { labels[accountID] = try await service.listGmailLabels(accountID: accountID) }
            catch { message = error.localizedDescription }
        }
    }

    func proposeThreadMutation(
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

    func requestActiveApproval(model: DesktopAppModel) {
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

    func executeActiveThreadMutation(model: DesktopAppModel, mutation: GmailThreadMutation) {
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

    func proposeOutbound(model: DesktopAppModel, draft: DesktopEmailDraft, account: NativeGoogleAccountSnapshot, send: Bool) {
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

    func executeOutbound(model: DesktopAppModel, draft: DesktopEmailDraft, send: Bool) {
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
                    remoteReceipt = "Sent message \(receipt.messageID) was re-read from Gmail."
                } else {
                    let receipt = try await service.createGmailDraft(accountID: action.accountID, message: outbound, grant: grant)
                    remoteReceipt = "Draft \(receipt.id) was re-read from Gmail."
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

    func saveAttachment(accountID: String, attachment: GmailAttachmentSnapshot) {
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

    func createStandingRule(
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

    func runStandingRule(model: DesktopAppModel, rule: DesktopMailStandingRule) {
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

    private func authorizedAction(model: DesktopAppModel) -> DesktopMailActionRecord? {
        guard let action = activeAction(model: model) else { return nil }
        if action.standingRuleID != nil { return action }
        guard let approvalID = action.approvalID,
              model.snapshot.operations.approvals.first(where: { $0.id == approvalID })?.state == .approved else { return nil }
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
