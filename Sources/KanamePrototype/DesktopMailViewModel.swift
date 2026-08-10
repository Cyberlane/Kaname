import AppKit
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

    init(environment: KanameDesktopEnvironment = .current) {
        service = NativeGoogleIntegrationService(
            rootDirectory: environment.googleDirectory,
            keychainService: environment.googleKeychainService
        )
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
