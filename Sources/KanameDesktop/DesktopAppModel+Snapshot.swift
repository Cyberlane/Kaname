import Combine
import CryptoKit
import Foundation
import KanameConnectivity
import KanameDomain
import KanameLocalCore
#if os(macOS)
import Darwin
#endif

public struct DesktopAppSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = KanameDesktopStateSchema.currentVersion

    public var version: Int
    public var projects: [DesktopProject]
    public var threads: [DesktopThread]
    public var remote: DesktopRemoteStatus
    public var preferences: DesktopPreferences
    public var domains: DesktopDomainSnapshot
    public var operations: DesktopOperationalSnapshot
    public var lastSavedAtUnixMillis: Int64

    public init(
        version: Int,
        projects: [DesktopProject],
        threads: [DesktopThread],
        remote: DesktopRemoteStatus,
        preferences: DesktopPreferences,
        domains: DesktopDomainSnapshot,
        operations: DesktopOperationalSnapshot,
        lastSavedAtUnixMillis: Int64
    ) {
        (self.version, self.projects, self.threads) = (version, projects, threads)
        (self.remote, self.preferences, self.domains) = (remote, preferences, domains)
        self.operations = operations
        self.lastSavedAtUnixMillis = lastSavedAtUnixMillis
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case projects
        case threads
        case remote
        case preferences
        case domains
        case operations
        case lastSavedAtUnixMillis
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        projects = try container.decode([DesktopProject].self, forKey: .projects)
        threads = try container.decode([DesktopThread].self, forKey: .threads)
        remote = try container.decode(DesktopRemoteStatus.self, forKey: .remote)
        preferences = try container.decode(DesktopPreferences.self, forKey: .preferences)
        domains = try container.decodeIfPresent(DesktopDomainSnapshot.self, forKey: .domains) ?? .empty
        operations = try container.decodeIfPresent(DesktopOperationalSnapshot.self, forKey: .operations) ?? .empty
        lastSavedAtUnixMillis = try container.decode(Int64.self, forKey: .lastSavedAtUnixMillis)
    }

    public static func starter(now: Int64) -> DesktopAppSnapshot {
        let project = DesktopProject(
            id: "project-kaname",
            name: "Kaname",
            summary: "Local-first personal agent workspace",
            context: DesktopProjectContext(
                instructionReferences: ["AGENTS.md"],
                knowledgeSourceIDs: ["knowledge-coding-ade", "knowledge-kaname-repository"],
                skillIDs: ["skill-mori-review", "skill-obsidian"],
                defaultKind: .coding,
                defaultProvider: "Codex",
                defaultModel: "Use provider default"
            ),
            createdAtUnixMillis: now
        )
        return DesktopAppSnapshot(
            version: currentVersion,
            projects: [project],
            threads: [
                DesktopThread(
                    id: "thread-desktop-dogfood",
                    projectID: project.id,
                    title: "Starter · Kaname desktop dogfood",
                    summary: "Starter context only. Workspace qualification has not run in this fresh state.",
                    kind: .coding,
                    attention: .needsResponse,
                    provider: "Codex",
                    model: "Use provider default",
                    updatedAtUnixMillis: now,
                    unread: true,
                    messages: [
                        DesktopMessage(
                            id: "message-desktop-brief",
                            role: .user,
                            body: "Build a polished desktop app that can become the primary place to work on Kaname.",
                            createdAtUnixMillis: now - 2_000
                        ),
                        DesktopMessage(
                            id: "message-desktop-ready",
                            role: .assistant,
                            body: "This starter describes the intended foundation. It is not an operational receipt; build, test, packaging, and visual qualification are unknown until run.",
                            createdAtUnixMillis: now - 1_000
                        ),
                    ],
                    plan: [
                        DesktopPlanItem(title: "Verify the persistent desktop foundation", state: .pending),
                        DesktopPlanItem(title: "Verify devices and remote health", state: .pending),
                        DesktopPlanItem(title: "Run packaging and interactive QA", state: .pending),
                    ],
                    evidence: [
                        DesktopEvidence(label: "Swift tests", detail: "Not run for this workspace state", state: .notRun),
                        DesktopEvidence(label: "Rust tests", detail: "Not run for this workspace state", state: .notRun),
                        DesktopEvidence(label: "Packaged app", detail: "Signing, installation, and visual qualification not run", state: .notRun),
                        DesktopEvidence(label: "Local core", detail: "Replay and transport qualification not run", state: .notRun),
                    ]
                ),
                DesktopThread(
                    id: "thread-phase3-mobile",
                    projectID: project.id,
                    title: "Starter · Mobile qualification",
                    summary: "Remote and mobile foundations are available; qualification has not run in this fresh state.",
                    kind: .planning,
                    attention: .needsResponse,
                    provider: "Kaname",
                    model: "External input required",
                    updatedAtUnixMillis: now - 60_000,
                    unread: true,
                    messages: [
                        DesktopMessage(
                            id: "message-phase3-boundary",
                            role: .system,
                            body: "Physical-device and paid-team APNs evidence remain deferred. The connected charging iPhone is excluded.",
                            createdAtUnixMillis: now - 60_000
                        ),
                    ],
                    evidence: [
                        DesktopEvidence(label: "Hosted relay", detail: "Not run; remote state is unknown", state: .notRun),
                        DesktopEvidence(label: "Simulator recovery", detail: "Not run for this workspace state", state: .notRun),
                        DesktopEvidence(label: "Physical device", detail: "Not run; explicitly deferred", state: .notRun),
                    ]
                ),
                DesktopThread(
                    id: "thread-local-core",
                    projectID: project.id,
                    title: "Starter · Local authority health",
                    summary: "Local-core foundations are configured; current health and qualification are unknown.",
                    kind: .coding,
                    attention: .needsInput,
                    provider: "Kaname local core",
                    model: "Provider-free",
                    updatedAtUnixMillis: now - 120_000,
                    evidence: [
                        DesktopEvidence(label: "Local core", detail: "Acceptance corpus not run for this workspace state", state: .notRun),
                        DesktopEvidence(label: "Codex adapter", detail: "Accepted workflow not run for this workspace state", state: .notRun),
                    ]
                ),
            ],
            remote: .unverifiedFoundation(),
            preferences: DesktopPreferences(),
            domains: .starter(now: now),
            operations: .empty,
            lastSavedAtUnixMillis: now
        )
    }

    func migratedToCurrent(now: Int64) throws -> DesktopAppSnapshot {
        guard (1..<Self.currentVersion).contains(version) else { throw DesktopModelError.unsupportedVersion }
        var migrated = self
        while migrated.version < Self.currentVersion {
            switch migrated.version {
            case 1:
                break
            case 2:
                if migrated.domains == .empty {
                    migrated.domains = .starter(now: now)
                }
            case 3, 4, 5:
                break
            case 6:
                if let index = migrated.projects.firstIndex(where: { $0.id == "project-kaname" }),
                   migrated.projects[index].context == .empty {
                    migrated.projects[index].context = DesktopProjectContext(
                        instructionReferences: ["AGENTS.md"],
                        knowledgeSourceIDs: ["knowledge-coding-ade", "knowledge-kaname-repository"],
                        skillIDs: ["skill-mori-review", "skill-obsidian"]
                    )
                }
            case 7, 8, 9, 10, 11, 12, 13:
                break
            case 14:
                let terminalRunIDs = Set(migrated.operations.providerRuns.compactMap { run in
                    switch run.state {
                    case .completed, .failed, .interrupted, .rejected, .cancelled:
                        run.id
                    case .proposed, .awaitingApproval, .approved, .running, .reconciled:
                        nil
                    }
                })
                migrated.operations.providerEvents.removeAll { event in
                    terminalRunIDs.contains(event.runID)
                        && (event.kind == .assistantText || event.kind == .native)
                }
                for index in migrated.operations.providerEvents.indices
                    where terminalRunIDs.contains(migrated.operations.providerEvents[index].runID) {
                    migrated.operations.providerEvents[index].rawPayloadBase64 = nil
                }
            case 15:
                for index in migrated.threads.indices {
                    migrated.threads[index].createdAtUnixMillis = migrated.threads[index].messages
                        .map(\.createdAtUnixMillis)
                        .min() ?? migrated.threads[index].updatedAtUnixMillis
                }
            case 16:
                // Workflow state decodes to an empty collection for older snapshots.
                // Advancing the schema prevents an older build from silently
                // discarding workflow history after it has been created.
                break
            case 17:
                // Capability receipts and runtime leases are additive. Built-in
                // capabilities are regenerated from this exact Kaname build;
                // imported/private capabilities remain explicit installations.
                if migrated.operations.workflows.capabilityInstallations.isEmpty {
                    migrated.operations.workflows.capabilityInstallations =
                        DesktopWorkflowBuiltinCapabilities.installations(at: now)
                }
                migrated.operations.workflows.runtimeClaims.removeAll()
            case 18:
                // Artifact roles, schema-validated state, and reviewed knowledge
                // decode additively. A new schema prevents older builds from
                // silently discarding their durable workflow data plane.
                break
            case 19:
                // Typed graph decisions, structured reviews, resumable waits,
                // datasets, connector previews, authority grants, and bounded
                // execution evidence decode additively into the workflow host.
                break
            case 20:
                // Production mail reads, connector effects, and bounded agent
                // execution are built-in host capabilities. Merge them by ID so
                // existing installations gain the new host surface without
                // replacing private or explicitly configured capabilities.
                let installedIDs = Set(
                    migrated.operations.workflows.capabilityInstallations.map(\.capabilityID)
                )
                migrated.operations.workflows.capabilityInstallations.append(
                    contentsOf: DesktopWorkflowBuiltinCapabilities.installations(at: now)
                        .filter { !installedIDs.contains($0.capabilityID) }
                )
            case 21:
                // Trigger health, ownership, extension bindings, reusable
                // components, schedules, and migration evidence are additive.
                // They intentionally start empty so older workspaces do not
                // silently gain observation or effect authority.
                break
            case 22:
                // Manifest-v3 installation, configuration, binding, dependency,
                // capture, and retention revisions decode additively. Existing
                // definitions retain their legacy behavior and gain no new
                // observation, secret, or effect authority during migration.
                break
            case 23:
                // Studio presentation metadata, typed mappings, undo history,
                // and durable batch items decode additively. No graph is
                // rewritten and no execution or effect authority is granted.
                break
            case 24:
                // Authority history, content lifecycle receipts, and quiet
                // operational status decode additively. Existing grants retain
                // their exact scope and no captured content is purged during
                // migration.
                break
            case 25:
                // Signed-template verification, deterministic workflow
                // simulation, exact dependency locks on runs, and
                // revision-bound migration comparisons decode additively.
                // Existing workflows gain no authority or migration evidence.
                break
            case 26:
                // Coding workflow and knowledge-lane records decode additively.
                // Existing conversations gain no implementation, acceptance,
                // or knowledge-write authority during migration.
                break
            case 27:
                // Remove only the exact legacy starter signatures that looked
                // like current acceptance receipts. User-created, edited, and
                // independently recorded evidence is preserved byte-for-byte.
                migrated.normalizeLegacyStarterClaims()
                // Application turns are owned by Kaname and remain stable
                // across provider retries and coding workflow phases. Native
                // provider turn IDs are intentionally not used for backfill.
                for index in migrated.operations.providerRuns.indices {
                    let run = migrated.operations.providerRuns[index]
                    if let sourceMessageID = run.sourceMessageID {
                        guard let threadID = run.threadID,
                              migrated.threads.first(where: { $0.id == threadID })?.messages.contains(where: {
                                  $0.id == sourceMessageID && $0.role == .user
                              }) == true else {
                            throw DesktopModelError.invalidState
                        }
                    }
                    migrated.operations.providerRuns[index].turnID = run.sourceMessageID ?? run.id
                }
                var runIdentities: [String: (turnID: String, threadID: String?)] = [:]
                for run in migrated.operations.providerRuns {
                    let identity = (turnID: run.turnID, threadID: run.threadID)
                    guard runIdentities.updateValue(identity, forKey: run.id) == nil else {
                        throw DesktopModelError.invalidState
                    }
                }
                for index in migrated.operations.providerEvents.indices {
                    let event = migrated.operations.providerEvents[index]
                    guard let identity = runIdentities[event.runID],
                          identity.threadID == event.threadID else {
                        throw DesktopModelError.invalidState
                    }
                    migrated.operations.providerEvents[index].turnID = identity.turnID
                }
                for threadIndex in migrated.threads.indices {
                    let containingThreadID = migrated.threads[threadIndex].id
                    migrated.threads[threadIndex].messages = try migrated.threads[threadIndex].messages.map { message in
                        let turnID: String?
                        switch message.role {
                        case .user:
                            turnID = message.id
                        case .assistant:
                            let prefix = "assistant-"
                            let runID = message.id.hasPrefix(prefix)
                                ? String(message.id.dropFirst(prefix.count))
                                : nil
                            if let runID {
                                guard let identity = runIdentities[runID],
                                      identity.threadID == containingThreadID else {
                                    throw DesktopModelError.invalidState
                                }
                                turnID = identity.turnID
                            } else {
                                turnID = nil
                            }
                        case .system:
                            turnID = nil
                        }
                        return DesktopMessage(
                            id: message.id,
                            turnID: turnID,
                            role: message.role,
                            body: message.body,
                            attachments: message.attachments,
                            createdAtUnixMillis: message.createdAtUnixMillis
                        )
                    }
                }
            default:
                throw DesktopModelError.unsupportedVersion
            }
            migrated.version += 1
        }
        return migrated
    }

    private mutating func normalizeLegacyStarterClaims() {
        if let index = threads.firstIndex(where: { $0.id == "thread-desktop-dogfood" }) {
            if threads[index].title == "Kaname desktop dogfood" {
                threads[index].title = "Starter · Kaname desktop dogfood"
            }
            if threads[index].summary == "The polished desktop workspace is installed and ready for dogfooding." {
                threads[index].summary = "Starter context only. Workspace qualification has not run in this fresh state."
            }
            for messageIndex in threads[index].messages.indices
                where threads[index].messages[messageIndex].id == "message-desktop-ready"
                    && threads[index].messages[messageIndex].body == "The persistent workspace, integrated safety surfaces, private local core, release packaging, and visual qualification are ready." {
                let legacyMessage = threads[index].messages[messageIndex]
                threads[index].messages[messageIndex] = DesktopMessage(
                    id: legacyMessage.id,
                    role: legacyMessage.role,
                    body: "This starter describes the intended foundation. It is not an operational receipt; build, test, packaging, and visual qualification are unknown until run.",
                    attachments: legacyMessage.attachments,
                    createdAtUnixMillis: legacyMessage.createdAtUnixMillis
                )
            }
            let legacyPlans: [String: String] = [
                "Persistent desktop workspace": "Verify the persistent desktop foundation",
                "Integrated devices and remote health": "Verify devices and remote health",
                "Packaging and interactive QA": "Run packaging and interactive QA",
            ]
            for planIndex in threads[index].plan.indices {
                let item = threads[index].plan[planIndex]
                if item.state == .complete, let replacement = legacyPlans[item.title] {
                    threads[index].plan[planIndex].title = replacement
                    threads[index].plan[planIndex].state = .pending
                }
            }
            let legacyEvidence: [String: (String, String)] = [
                "Full desktop suite passed": ("Swift tests", "Not run for this workspace state"),
                "26 tests passed": ("Rust tests", "Not run for this workspace state"),
                "Signed, installed, and visually qualified": ("Packaged app", "Signing, installation, and visual qualification not run"),
                "F-01 through F-14 replayed through Mach XPC": ("Local core", "Replay and transport qualification not run"),
            ]
            for evidenceIndex in threads[index].evidence.indices {
                let evidence = threads[index].evidence[evidenceIndex]
                if evidence.state == .passed,
                   let replacement = legacyEvidence[evidence.detail],
                   evidence.label == replacement.0 {
                    threads[index].evidence[evidenceIndex].detail = replacement.1
                    threads[index].evidence[evidenceIndex].state = .notRun
                }
            }
        }

        if let index = threads.firstIndex(where: { $0.id == "thread-phase3-mobile" }) {
            if threads[index].title == "Phase 3 mobile qualification" {
                threads[index].title = "Starter · Mobile qualification"
            }
            if threads[index].summary == "Simulator, hosted relay, reconciliation, recovery, and cleanup are complete." {
                threads[index].summary = "Remote and mobile foundations are available; qualification has not run in this fresh state."
            }
            let replacements: [String: String] = [
                "Clean after bounded qualification": "Not run; remote state is unknown",
                "Restart and reconciliation passed": "Not run for this workspace state",
                "Explicitly deferred": "Not run; explicitly deferred",
            ]
            for evidenceIndex in threads[index].evidence.indices {
                let evidence = threads[index].evidence[evidenceIndex]
                if let replacement = replacements[evidence.detail] {
                    threads[index].evidence[evidenceIndex].detail = replacement
                    threads[index].evidence[evidenceIndex].state = .notRun
                }
            }
        }

        if let index = threads.firstIndex(where: { $0.id == "thread-local-core" }) {
            if threads[index].title == "Local authority health" {
                threads[index].title = "Starter · Local authority health"
            }
            if threads[index].summary == "Signed XPC and durable Rust journal evidence remain available for inspection." {
                threads[index].summary = "Local-core foundations are configured; current health and qualification are unknown."
            }
            let replacements: [String: String] = [
                "Phase 1 acceptance corpus passed": "Acceptance corpus not run for this workspace state",
                "Phase 2 accepted workflow passed": "Accepted workflow not run for this workspace state",
            ]
            var replacedEvidence = false
            for evidenceIndex in threads[index].evidence.indices {
                let evidence = threads[index].evidence[evidenceIndex]
                if evidence.state == .passed, let replacement = replacements[evidence.detail] {
                    threads[index].evidence[evidenceIndex].detail = replacement
                    threads[index].evidence[evidenceIndex].state = .notRun
                    replacedEvidence = true
                }
            }
            if replacedEvidence, threads[index].attention == .completed {
                threads[index].attention = .needsInput
            }
        }

        let legacyRemoteEvents = [
            ("remote-relay-rehearsal", "Encrypted relay rehearsal", "Enrollment, edited queue, receipts, stale approval, rotation, revocation, and cleanup passed.", DesktopRemoteEvent.State.passed),
            ("remote-restart-recovery", "Restart recovery", "Enrollment, key custody, queue, receipts, history, and pending rotation recover safely.", DesktopRemoteEvent.State.passed),
            ("remote-apns-contract", "APNs payload contract", "Only a generic content-free attention hint is sent; encrypted work remains in the relay.", DesktopRemoteEvent.State.passed),
            ("remote-physical-iphone", "Physical iPhone qualification", "Deferred until a different iPhone is explicitly designated.", DesktopRemoteEvent.State.deferred),
        ]
        let hasExactLegacyRemote = remote.relayStatus == "Hosted relay clean"
            && remote.enrollmentStatus == "Simulator qualified · physical device deferred"
            && remote.notificationStatus == "Privacy contract passed · APNs credentials deferred"
            && remote.queueStatus == "Restart-safe · 0 pending after terminal receipts"
            && remote.events.count == legacyRemoteEvents.count
            && zip(remote.events, legacyRemoteEvents).allSatisfy { pair in
                let (event, expected) = pair
                return event.id == expected.0 && event.title == expected.1
                    && event.detail == expected.2 && event.state == expected.3
            }
        if hasExactLegacyRemote {
            remote = .unverifiedFoundation()
        }

        for index in operations.workflows.capabilityInstallations.indices {
            let capability = operations.workflows.capabilityInstallations[index]
            if DesktopWorkflowBuiltinCapabilities.identifiers.contains(capability.capabilityID),
               capability.runtime == .builtIn,
               capability.trust == .kanameBuiltIn,
               capability.lastTestPassed,
               capability.lastTestedAtUnixMillis == capability.installedAtUnixMillis {
                operations.workflows.capabilityInstallations[index].lastTestedAtUnixMillis = nil
                operations.workflows.capabilityInstallations[index].lastTestPassed = false
            }
        }
    }
}

extension DesktopAppSnapshot {
    @discardableResult
    mutating func attachWorkflowProviderLinkage(
        providerRunID: String,
        stepAttemptID: String,
        run: DesktopWorkflowRunRecord,
        attempt: DesktopWorkflowStepAttemptRecord
    ) -> Bool {
        changeTwoRecords(
            first: \.operations.providerRuns, id: providerRunID,
            change: { storedRun in
                storedRun.workflowWorkItemID = run.workItemID
                storedRun.workflowEpisodeID = run.episodeID
                storedRun.workflowRunID = run.id
                storedRun.workflowStepAttemptID = attempt.id
                storedRun.workflowContextSnapshotID = run.contextSnapshotID
            },
            second: \.operations.workflows.stepAttempts, id: stepAttemptID,
            change: { $0.providerRunID = providerRunID }
        )
    }

    mutating func appendWorkflowRecord<Record>(
        _ record: Record,
        at keyPath: WritableKeyPath<DesktopAppSnapshot, [Record]>,
        workItemID: String,
        workState: DesktopWorkflowWorkState? = nil,
        nextAction: String,
        updatedAtUnixMillis: Int64
    ) {
        self[keyPath: keyPath].append(record)
        setWorkflowWorkItemPresentation(
            id: workItemID, state: workState, nextAction: nextAction,
            updatedAtUnixMillis: updatedAtUnixMillis
        )
    }

    @discardableResult
    mutating func changeTwoRecords<First: Identifiable, Second: Identifiable>(
        first firstPath: WritableKeyPath<DesktopAppSnapshot, [First]>,
        id firstID: String,
        change firstChange: (inout First) -> Void,
        second secondPath: WritableKeyPath<DesktopAppSnapshot, [Second]>,
        id secondID: String,
        change secondChange: (inout Second) -> Void
    ) -> Bool where First.ID == String, Second.ID == String {
        guard changeRecord(at: firstPath, id: firstID, change: firstChange) else { return false }
        return changeRecord(at: secondPath, id: secondID, change: secondChange)
    }

    @discardableResult
    mutating func setWorkflowWorkItemPresentation(
        id: String,
        state: DesktopWorkflowWorkState? = nil,
        nextAction: String,
        updatedAtUnixMillis: Int64
    ) -> Bool {
        changeRecord(at: \.operations.workflows.workItems, id: id) { item in
            if let state { item.state = state }
            item.nextAction = nextAction
            item.updatedAtUnixMillis = updatedAtUnixMillis
        }
    }

    mutating func appendAudit(
        domain: String,
        action: String,
        target: String,
        state: DesktopActionState,
        detail: String,
        recordedAtUnixMillis: Int64
    ) {
        operations.audit.append(DesktopAuditRecord(
            id: UUID().uuidString.lowercased(), domain: domain, action: action,
            target: target, state: state, detail: detail,
            recordedAtUnixMillis: recordedAtUnixMillis
        ))
    }

    @discardableResult
    mutating func rebaselineWorkflowTrigger(id: String, at timestamp: Int64) -> Bool {
        guard changeRecord(
            at: \.operations.workflows.triggerBindings, id: id,
            change: { binding in
                binding.lastCursor = nil
                binding.updatedAtUnixMillis = timestamp
            }
        ) else { return false }
        _ = changeRecord(at: \.operations.workflows.triggerHealth, id: id) { health in
            health.state = .unknown
            health.nextAttemptAtUnixMillis = nil
            health.consecutiveFailures = 0
            health.errorCode = nil
            health.errorSummary = nil
            health.authenticationRequired = false
        }
        appendAudit(
            domain: "workflow-trigger", action: "rebaseline-requested", target: "binding:\(id)",
            state: .completed,
            detail: "The next trigger check will establish a new cursor without replaying existing remote items.",
            recordedAtUnixMillis: timestamp
        )
        return true
    }

    @discardableResult
    mutating func changeRecord<Record: Identifiable>(
        at keyPath: WritableKeyPath<DesktopAppSnapshot, [Record]>,
        id: String,
        change: (inout Record) -> Void
    ) -> Bool where Record.ID == String {
        guard let index = self[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { return false }
        change(&self[keyPath: keyPath][index])
        return true
    }
}

private enum DesktopModelError: Error {
    case unsupportedVersion
    case invalidState
}
