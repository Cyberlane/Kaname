import Foundation
import KanameConnectivity
import KanameDesktop
@preconcurrency import UserNotifications

@MainActor
final class DesktopAutomationSchedulerViewModel: ObservableObject {
    @Published private(set) var ownerState = "Starting"
    @Published private(set) var lastEvaluatedAt: Date?
    @Published private(set) var message: String?

    private let model: DesktopAppModel
    private let runtime: DesktopConversationRuntime
    private let ownerID = UUID().uuidString.lowercased()
    private let leaseStore: DesktopSchedulerLeaseStore
    private var loop: Task<Void, Never>?

    init(
        model: DesktopAppModel,
        runtime: DesktopConversationRuntime,
        environment: KanameDesktopEnvironment = .current
    ) {
        self.model = model
        self.runtime = runtime
        leaseStore = DesktopSchedulerLeaseStore(directory: environment.desktopDirectory.appending(path: "Scheduler", directoryHint: .isDirectory))
        guard !CommandLine.arguments.contains("--snapshot") else {
            ownerState = "Disabled during snapshot qualification"
            return
        }
        loop = Task { [weak self] in await self?.runLoop() }
    }

    deinit {
        loop?.cancel()
        leaseStore.release(ownerID: ownerID)
    }

    func evaluateNow() {
        Task { await evaluate() }
    }

    func requestNotificationAccess() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                message = granted ? "Local automation notifications are enabled." : "Notification access was not granted. Rules still retain durable run history."
            } catch { message = error.localizedDescription }
        }
    }

    func executeApproved(runID: String) {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        do {
            _ = try leaseStore.acquire(ownerID: ownerID, nowUnixMillis: timestamp)
        } catch {
            message = "Another Kaname scheduler owns execution. This occurrence remains approved and was not dispatched."
            return
        }
        guard let run = model.beginApprovedAutomationRun(id: runID) else {
            message = "Approve this exact occurrence in Inbox first."
            return
        }
        execute(run)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await evaluate()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func evaluate() async {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        do {
            _ = try leaseStore.acquire(ownerID: ownerID, nowUnixMillis: timestamp)
            ownerState = "This Kaname instance owns the scheduler lease"
        } catch {
            ownerState = "Standby — another Kaname scheduler owns execution"
            return
        }
        lastEvaluatedAt = .now
        for run in model.snapshot.operations.automationRuns where run.state == .running {
            reconcileRunning(run)
        }
        for run in model.snapshot.operations.automationRuns where run.state == .approved {
            guard let begun = model.beginApprovedAutomationRun(id: run.id) else { continue }
            execute(begun)
        }
        for id in model.dueAutomationIDs(atUnixMillis: timestamp) {
            guard let runID = model.claimAutomationRun(id: id, ownerID: ownerID, nowUnixMillis: timestamp),
                  let run = model.automationRun(id: runID) else { continue }
            if run.state == .awaitingApproval {
                requestApproval(for: run)
            } else if run.state == .approved, let begun = model.beginApprovedAutomationRun(id: run.id) {
                execute(begun)
            }
        }
        for run in model.snapshot.operations.automationRuns where run.state == .awaitingApproval {
            if let approvalID = run.approvalID,
               let exactTarget = run.exactTarget,
               model.isApprovalGranted(id: approvalID, exactTarget: exactTarget),
               let begun = model.beginApprovedAutomationRun(id: run.id) {
                execute(begun)
            } else {
                requestApproval(for: run)
            }
        }
    }

    private func requestApproval(for run: DesktopAutomationRunRecord) {
        guard let rule = model.snapshot.domains.automations.first(where: { $0.id == run.automationID }) else { return }
        guard let target = run.exactTarget else {
            model.completeAutomationRun(id: run.id, state: .failed, detail: "The frozen occurrence authority target is unavailable.")
            return
        }
        if let approvalID = run.approvalID,
           let existing = model.snapshot.operations.approvals.first(where: { $0.id == approvalID }),
           existing.state == .awaitingApproval,
           existing.exactTarget == target,
           existing.expiresAtUnixMillis.map({ $0 >= Int64(Date().timeIntervalSince1970 * 1_000) }) ?? true {
            return
        }
        let approvalID = model.createApproval(
            threadID: nil,
            title: "Run automation: \(rule.name)",
            exactTarget: target,
            consequence: rule.actionSummary,
            dataLeavingDevice: rule.actionKind == .notification ? "Nothing" : "The resolved prompt and selected project, skill, and tool references",
            reversible: rule.actionKind == .notification,
            expiresAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000) + 86_400_000
        )
        if let approvalID { model.attachAutomationApproval(runID: run.id, approvalID: approvalID) }
        message = "A scheduled occurrence needs review in Inbox."
    }

    private func execute(_ run: DesktopAutomationRunRecord) {
        guard let rule = model.snapshot.domains.automations.first(where: { $0.id == run.automationID }),
              let action = rule.actionKind else {
            model.completeAutomationRun(id: run.id, state: .failed, detail: "The automation contract is incomplete.")
            return
        }
        guard model.automationRunContractIsCurrent(id: run.id) else {
            model.completeAutomationRun(
                id: run.id,
                state: .failed,
                detail: "The project or capability context changed after approval. Nothing was dispatched; review a fresh occurrence."
            )
            return
        }
        guard !model.snapshot.preferences.safeMode || action == .notification else {
            model.completeAutomationRun(
                id: run.id,
                state: .failed,
                detail: "Safe mode blocked this provider dispatch before any data left the Mac."
            )
            return
        }
        switch action {
        case .notification:
            deliverNotification(rule: rule, run: run)
        case .conversation, .skill:
            let threadID = model.createConversation(kind: .personal, projectID: rule.projectID)
            let skillNames = (rule.skillIDs ?? []).compactMap { id in model.snapshot.domains.skills.first { $0.id == id }?.name }
            let context = [
                rule.actionSummary,
                skillNames.isEmpty ? nil : "Selected read-only skill context: \(skillNames.joined(separator: ", "))",
                "Scheduled occurrence: \(run.scheduledAtUnixMillis); deduplication key: \(run.deduplicationKey ?? run.id)",
            ].compactMap { $0 }.joined(separator: "\n\n")
            if let providerRunID = runtime.prepareEnqueue(
                threadID: threadID,
                body: context,
                usesProjectContext: false,
                workspacePathOverride: run.workspacePath
            ) {
                if model.attachAutomationDispatch(runID: run.id, threadID: threadID, providerRunID: providerRunID) {
                    runtime.resumePrepared(runID: providerRunID)
                } else {
                    message = "Kaname could not durably link this occurrence. Nothing was dispatched; retry after local storage recovers."
                }
            } else {
                model.completeAutomationRun(id: run.id, state: .failed, detail: "Kaname could not queue the resolved conversation.", threadID: threadID)
            }
        }
    }

    private func reconcileRunning(_ run: DesktopAutomationRunRecord) {
        guard let rule = model.snapshot.domains.automations.first(where: { $0.id == run.automationID }),
              let action = rule.actionKind else {
            model.completeAutomationRun(id: run.id, state: .failed, detail: "The automation contract disappeared during recovery.")
            return
        }
        if action == .notification {
            deliverNotification(rule: rule, run: run)
            return
        }
        guard let providerRunID = run.providerRunID, let providerRun = model.providerRun(id: providerRunID) else {
            model.completeAutomationRun(
                id: run.id,
                state: .failed,
                detail: "Recovery found no durable provider-run receipt. Kaname did not retry because that could duplicate the occurrence.",
                threadID: run.threadID
            )
            return
        }
        switch providerRun.state {
        case .completed:
            model.completeAutomationRun(
                id: run.id,
                state: .completed,
                detail: "The linked read-only provider run completed.",
                threadID: run.threadID
            )
            deliverCompletionNotificationIfEnabled(rule: rule, run: run)
        case .failed, .interrupted, .cancelled, .rejected:
            model.completeAutomationRun(
                id: run.id,
                state: .failed,
                detail: providerRun.errorSummary ?? "The linked provider run stopped before completion.",
                threadID: run.threadID
            )
            deliverCompletionNotificationIfEnabled(rule: rule, run: run)
        case .proposed:
            runtime.resumePrepared(runID: providerRunID)
        case .awaitingApproval, .approved, .running, .reconciled:
            break
        }
    }

    private func deliverNotification(rule: DesktopAutomationRule, run: DesktopAutomationRunRecord) {
        Task {
            let center = UNUserNotificationCenter.current()
            let identifier = run.deduplicationKey ?? run.id
            if await notificationExists(identifier: identifier, center: center) {
                model.completeAutomationRun(id: run.id, state: .completed, detail: "Reconciled the existing local notification without delivering it twice.", notificationState: "reconciled")
                return
            }
            let settings = await notificationSettings(center: center)
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                model.completeAutomationRun(
                    id: run.id,
                    state: .failed,
                    detail: "The occurrence was claimed once, but notification permission is unavailable.",
                    notificationState: settings.authorizationStatus == .denied ? "denied" : "not requested"
                )
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Kaname reminder"
            content.body = model.snapshot.preferences.previewPrivacy == .hidden
                ? "A scheduled reminder is ready."
                : "The scheduled rule “\(rule.name)” is ready."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            do {
                try await center.add(request)
                model.completeAutomationRun(id: run.id, state: .completed, detail: "Queued one idempotent local notification.", notificationState: "queued")
            } catch {
                model.completeAutomationRun(id: run.id, state: .failed, detail: error.localizedDescription, notificationState: "failed")
            }
        }
    }

    private func deliverCompletionNotificationIfEnabled(rule: DesktopAutomationRule, run: DesktopAutomationRunRecord) {
        guard rule.notificationEnabled == true else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await notificationSettings(center: center)
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                model.updateAutomationNotificationState(
                    runID: run.id,
                    state: settings.authorizationStatus == .denied ? "completion denied" : "completion not requested"
                )
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Kaname automation finished"
            content.body = model.snapshot.preferences.previewPrivacy == .hidden
                ? "Open Kaname to review the result."
                : "The rule “\(rule.name)” has a new result."
            let request = UNNotificationRequest(identifier: "\(run.deduplicationKey ?? run.id):completion", content: content, trigger: nil)
            do {
                try await center.add(request)
                model.updateAutomationNotificationState(runID: run.id, state: "completion delivered")
            } catch {
                model.updateAutomationNotificationState(runID: run.id, state: "completion failed")
            }
        }
    }

    private func notificationSettings(center: UNUserNotificationCenter) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
    }

    private func notificationExists(identifier: String, center: UNUserNotificationCenter) async -> Bool {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { pending in
                if pending.contains(where: { $0.identifier == identifier }) {
                    continuation.resume(returning: true)
                    return
                }
                center.getDeliveredNotifications { delivered in
                    continuation.resume(returning: delivered.contains { $0.request.identifier == identifier })
                }
            }
        }
    }
}
