import Foundation
import KanameDesktop
import KanameLocalCore

/// Watches the durable run projection while the app is open and posts a local
/// notification when something needs Justin: a run that failed, or an effect
/// waiting for approval. Covers runs started by schedules, webhooks, and
/// pollers, which the Run history screen only reports when it is on screen.
/// The first observation is a baseline, so nothing already sitting in the
/// projection produces a notification at launch.
final class DesktopAutomationRunWatcher: @unchecked Sendable {
    static let shared = DesktopAutomationRunWatcher()

    private let queue = DispatchQueue(label: "com.cyberlane.kaname.automation-run-watcher", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isChecking = false
    private var seenRunStatus: [String: String] = [:]
    private var seenProposedEffects: Set<String> = []
    private var baselined = false

    private init() {}

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 20, repeating: 60)
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        }
    }

    private func check() {
        guard !isChecking, let runner = LocalCoreRunner.bundled() else { return }
        isChecking = true
        Task.detached { [self] in
            defer { queue.async { self.isChecking = false } }
            let loader = DesktopWorkflowRunHistoryLoader(
                inspection: DesktopWorkflowRunInspectionClient(transport: runner),
                library: DesktopWorkflowV2LibraryClient(transport: runner)
            )
            guard let snapshot = try? await loader.load(
                limit: 30, requestID: "run-watcher:\(UUID().uuidString.lowercased())"
            ) else { return }
            let observations = snapshot.runs.map { item in
                (
                    runID: item.run.runID,
                    // A run parked on a proposed effect reports failed with
                    // effect.not-authorized; that is the approval gate, not a failure.
                    status: item.run.errorCode == "effect.not-authorized" ? "awaiting-approval" : item.run.status,
                    name: item.graph?.name ?? item.run.workflowID,
                    proposedEffectIDs: item.run.effectAuthorities.filter { $0.status == "proposed" }.map(\.effectID)
                )
            }
            queue.async { self.reconcile(observations) }
        }
    }

    private func reconcile(_ observations: [(runID: String, status: String, name: String, proposedEffectIDs: [String])]) {
        var nextStatus: [String: String] = [:]
        var nextProposed: Set<String> = []
        var failed: [String] = []
        var proposed: [String] = []
        for observation in observations {
            nextStatus[observation.runID] = observation.status
            nextProposed.formUnion(observation.proposedEffectIDs)
            if baselined {
                if observation.status == "failed", seenRunStatus[observation.runID] != "failed" {
                    failed.append(observation.name)
                }
                for effectID in observation.proposedEffectIDs where !seenProposedEffects.contains(effectID) {
                    proposed.append(observation.name)
                }
            }
        }
        seenRunStatus = nextStatus
        seenProposedEffects = nextProposed
        baselined = true
        let failedNames = Array(Set(failed)).sorted()
        let proposedNames = Array(Set(proposed)).sorted()
        guard !failedNames.isEmpty || !proposedNames.isEmpty else { return }
        Task { @MainActor in
            for name in failedNames {
                DesktopCodingNotifier.notify(kind: .automationRunFailed, threadTitle: name, hideDetails: false)
            }
            for name in proposedNames {
                DesktopCodingNotifier.notify(kind: .effectProposed, threadTitle: name, hideDetails: false)
            }
        }
    }
}
