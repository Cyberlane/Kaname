import Foundation
@testable import KanameDesktop
import Testing

@MainActor
struct DesktopAutomationSchedulerTests {
    @Test
    func scheduleEngineHandlesSpringForwardWeeklyAndOnceSchedules() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let beforeSpringGap = try localMillis(
            year: 2026,
            month: 3,
            day: 7,
            hour: 3,
            minute: 0,
            timeZone: losAngeles
        )
        let springOccurrence = try #require(try DesktopScheduleEngine.nextOccurrence(
            spec: DesktopScheduleSpec(frequency: .daily, hour: 2, minute: 30),
            timeZoneIdentifier: losAngeles.identifier,
            after: beforeSpringGap
        ))
        let springComponents = calendar(in: losAngeles).dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: Date(timeIntervalSince1970: Double(springOccurrence) / 1_000)
        )
        #expect(springComponents.year == 2026)
        #expect(springComponents.month == 3)
        #expect(springComponents.day == 8)
        #expect(springComponents.hour == 3)
        #expect(springComponents.minute == 30)

        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let mondayAfterRun = try localMillis(
            year: 2026,
            month: 8,
            day: 10,
            hour: 9,
            minute: 1,
            timeZone: tokyo
        )
        let weeklyOccurrence = try #require(try DesktopScheduleEngine.nextOccurrence(
            spec: DesktopScheduleSpec(frequency: .weekly, hour: 9, minute: 0, weekday: 2),
            timeZoneIdentifier: tokyo.identifier,
            after: mondayAfterRun
        ))
        let weeklyComponents = calendar(in: tokyo).dateComponents(
            [.year, .month, .day, .weekday, .hour, .minute],
            from: Date(timeIntervalSince1970: Double(weeklyOccurrence) / 1_000)
        )
        #expect(weeklyComponents.year == 2026)
        #expect(weeklyComponents.month == 8)
        #expect(weeklyComponents.day == 17)
        #expect(weeklyComponents.weekday == 2)
        #expect(weeklyComponents.hour == 9)
        #expect(weeklyComponents.minute == 0)

        let once = weeklyOccurrence + 60_000
        let onceSpec = DesktopScheduleSpec(
            frequency: .once,
            hour: 0,
            minute: 0,
            onceAtUnixMillis: once
        )
        #expect(try DesktopScheduleEngine.nextOccurrence(
            spec: onceSpec,
            timeZoneIdentifier: "UTC",
            after: once - 1
        ) == once)
        #expect(try DesktopScheduleEngine.nextOccurrence(
            spec: onceSpec,
            timeZoneIdentifier: "UTC",
            after: once
        ) == nil)
    }

    @Test
    func schedulerLeaseAllowsOneOwnerAndRecoversOnlyAfterExpiry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-scheduler-lease-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var firstStore: DesktopSchedulerLeaseStore? = DesktopSchedulerLeaseStore(directory: directory)
        let secondStore = DesktopSchedulerLeaseStore(directory: directory)

        let first = try #require(try? firstStore?.acquire(
            ownerID: "owner-a",
            nowUnixMillis: 1_000,
            durationMillis: 1_000
        ))
        #expect(first.ownerID == "owner-a")
        #expect(first.expiresAtUnixMillis == 2_000)
        #expect(throws: DesktopScheduleError.leaseUnavailable) {
            try secondStore.acquire(ownerID: "owner-b", nowUnixMillis: 1_999, durationMillis: 1_000)
        }
        #expect(throws: DesktopScheduleError.leaseUnavailable) {
            try secondStore.acquire(ownerID: "owner-b", nowUnixMillis: 2_501, durationMillis: 1_000)
        }

        let renewed = try #require(try? firstStore?.acquire(
            ownerID: "owner-a",
            nowUnixMillis: 1_500,
            durationMillis: 1_000
        ))
        #expect(renewed.expiresAtUnixMillis == 2_500)
        firstStore = nil
        let recovered = try #require(try? secondStore.acquire(
            ownerID: "owner-b",
            nowUnixMillis: 2_501,
            durationMillis: 1_000
        ))
        #expect(recovered.ownerID == "owner-b")
        #expect(try secondStore.load() == recovered)

        secondStore.release(ownerID: "owner-a")
        #expect(try secondStore.load() == recovered)
        secondStore.release(ownerID: "owner-b")
        #expect(throws: (any Error).self) { try secondStore.load() }
    }

    @Test
    func appModelActivatesClaimsDeduplicatesAndAppliesMissedPolicies() throws {
        var clock: Int64 = 1_000_000
        let model = DesktopAppModel(store: SchedulerMemoryStore(), now: { clock })
        let scheduled = clock + 60_000

        let standingID = try #require(model.createAutomation(
            name: "Standing conversation",
            schedule: "Once",
            timeZoneIdentifier: "UTC",
            actionSummary: "Start a bounded planning conversation",
            missedRunPolicy: .skip,
            scheduleSpec: DesktopScheduleSpec(
                frequency: .once,
                hour: 0,
                minute: 0,
                onceAtUnixMillis: scheduled
            ),
            actionKind: .conversation,
            authority: .standing
        ))
        #expect(!model.activateAutomation(id: standingID, approvalID: nil))
        let standingRule = try #require(model.snapshot.domains.automations.first { $0.id == standingID })
        let standingAuthorityTarget = try #require(model.automationAuthorityTarget(for: standingRule))
        let wrongActivationApproval = try #require(model.createApproval(
            threadID: nil,
            title: "Activate altered automation",
            exactTarget: "automation:\(standingID):different-contract",
            consequence: "Must not authorize the current contract.",
            dataLeavingDevice: "Nothing",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.resolveApproval(id: wrongActivationApproval, approved: true)
        #expect(!model.activateAutomation(id: standingID, approvalID: wrongActivationApproval))
        let expiredActivationApproval = try #require(model.createApproval(
            threadID: nil,
            title: "Activate expiring automation",
            exactTarget: standingAuthorityTarget,
            consequence: "Authorizes the exact contract only before expiry.",
            dataLeavingDevice: "Nothing",
            reversible: true,
            expiresAtUnixMillis: clock + 1
        ))
        model.resolveApproval(id: expiredActivationApproval, approved: true)
        clock += 2
        #expect(!model.activateAutomation(id: standingID, approvalID: expiredActivationApproval))
        clock -= 2
        let activationApproval = try #require(model.createApproval(
            threadID: nil,
            title: "Activate standing automation",
            exactTarget: standingAuthorityTarget,
            consequence: "Allows the bounded automation to run at its schedule.",
            dataLeavingDevice: "Nothing until a run executes",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.resolveApproval(id: activationApproval, approved: true)
        #expect(model.activateAutomation(id: standingID, approvalID: activationApproval))
        #expect(model.snapshot.domains.automations.first { $0.id == standingID }?.nextRunAtUnixMillis == scheduled)

        clock = scheduled
        let standingRunID = try #require(model.claimAutomationRun(
            id: standingID,
            ownerID: "scheduler-owner",
            nowUnixMillis: clock
        ))
        let standingRun = try #require(model.automationRun(id: standingRunID))
        #expect(standingRun.state == .approved)
        #expect(standingRun.ownerID == "scheduler-owner")
        #expect(standingRun.deduplicationKey == DesktopScheduleEngine.deduplicationKey(
            automationID: standingID,
            scheduledAtUnixMillis: scheduled
        ))
        #expect(model.claimAutomationRun(id: standingID, ownerID: "scheduler-owner", nowUnixMillis: clock) == nil)
        #expect(model.snapshot.operations.automationRuns.filter { $0.automationID == standingID }.count == 1)

        let missedSkipID = try #require(makeOnceAutomation(
            in: model,
            scheduledAt: clock + 60_000,
            name: "Skip stale notification",
            authority: .localOnly,
            policy: .skip
        ))
        #expect(model.activateAutomation(id: missedSkipID, approvalID: nil))
        let skipRunID = try #require(model.claimAutomationRun(
            id: missedSkipID,
            ownerID: "scheduler-owner",
            nowUnixMillis: clock + 180_001
        ))
        let skipRun = try #require(model.automationRun(id: skipRunID))
        #expect(skipRun.wasMissed == true)
        #expect(skipRun.state == .completed)
        #expect(skipRun.startedAtUnixMillis == nil)
        #expect(skipRun.detail.contains("Skipped"))

        let missedAskID = try #require(makeOnceAutomation(
            in: model,
            scheduledAt: clock + 240_000,
            name: "Ask before catch-up",
            authority: .standing,
            policy: .ask
        ))
        let missedAskRule = try #require(model.snapshot.domains.automations.first { $0.id == missedAskID })
        let missedAskTarget = try #require(model.automationAuthorityTarget(for: missedAskRule))
        let askApproval = try #require(model.createApproval(
            threadID: nil,
            title: "Activate ask automation",
            exactTarget: missedAskTarget,
            consequence: "Activates a visible standing schedule.",
            dataLeavingDevice: "Nothing",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.resolveApproval(id: askApproval, approved: true)
        #expect(model.activateAutomation(id: missedAskID, approvalID: askApproval))
        let askRunID = try #require(model.claimAutomationRun(
            id: missedAskID,
            ownerID: "scheduler-owner",
            nowUnixMillis: clock + 360_001
        ))
        let askRun = try #require(model.automationRun(id: askRunID))
        #expect(askRun.wasMissed == true)
        #expect(askRun.state == .awaitingApproval)
        #expect(askRun.contractTarget == missedAskTarget)
        #expect(askRun.exactTarget == "\(missedAskTarget):occurrence=\(askRun.scheduledAtUnixMillis)")
        #expect(model.beginApprovedAutomationRun(id: askRunID) == nil)

        let wrongRunApproval = try #require(model.createApproval(
            threadID: nil,
            title: "Run missed automation",
            exactTarget: askRun.deduplicationKey ?? askRun.id,
            consequence: "Must not execute because this is not the frozen occurrence target.",
            dataLeavingDevice: "Resolved action context",
            reversible: false,
            expiresAtUnixMillis: nil
        ))
        model.resolveApproval(id: wrongRunApproval, approved: true)
        model.attachAutomationApproval(runID: askRunID, approvalID: wrongRunApproval)
        #expect(model.beginApprovedAutomationRun(id: askRunID) == nil)

        let frozenOccurrenceTarget = try #require(askRun.exactTarget)
        let expiredRunApproval = try #require(model.createApproval(
            threadID: nil,
            title: "Run expiring missed automation",
            exactTarget: frozenOccurrenceTarget,
            consequence: "Executes only before this occurrence approval expires.",
            dataLeavingDevice: "Resolved action context",
            reversible: false,
            expiresAtUnixMillis: clock + 1
        ))
        model.resolveApproval(id: expiredRunApproval, approved: true)
        model.attachAutomationApproval(runID: askRunID, approvalID: expiredRunApproval)
        clock += 2
        #expect(model.beginApprovedAutomationRun(id: askRunID) == nil)
        clock -= 2

        let runApproval = try #require(model.createApproval(
            threadID: nil,
            title: "Run missed automation",
            exactTarget: frozenOccurrenceTarget,
            consequence: "Executes this exact missed occurrence.",
            dataLeavingDevice: "Resolved action context",
            reversible: false,
            expiresAtUnixMillis: nil
        ))
        model.resolveApproval(id: runApproval, approved: true)
        model.attachAutomationApproval(runID: askRunID, approvalID: runApproval)
        #expect(model.beginApprovedAutomationRun(id: askRunID)?.state == .running)
    }

    @Test
    func missedRecurringBacklogCoalescesToOneRunAndTheFirstFutureOccurrence() throws {
        let timestamp: Int64 = 1_786_309_200_000
        let staleOccurrence = timestamp - (7 * 86_400_000)
        var snapshot = DesktopAppSnapshot.starter(now: staleOccurrence)
        var rule = DesktopAutomationRule(
            id: "automation-backlog",
            name: "Daily reminder",
            schedule: "Daily at 09:30",
            timeZoneIdentifier: "Asia/Tokyo",
            actionSummary: "Show one local reminder",
            missedRunPolicy: .skip,
            status: .ready,
            nextRunAtUnixMillis: staleOccurrence,
            lastResult: "Scheduled",
            createdAtUnixMillis: staleOccurrence - 1_000
        )
        let spec = DesktopScheduleSpec(frequency: .daily, hour: 9, minute: 30)
        rule.scheduleSpec = spec
        rule.actionKind = .notification
        rule.authority = .localOnly
        snapshot.domains.automations = [rule]
        let store = SchedulerMemoryStore(data: try JSONEncoder().encode(snapshot))
        let model = DesktopAppModel(store: store, now: { timestamp })

        let runID = try #require(model.claimAutomationRun(
            id: rule.id,
            ownerID: "scheduler-owner",
            nowUnixMillis: timestamp
        ))
        let run = try #require(model.automationRun(id: runID))
        let expectedNext = try #require(try DesktopScheduleEngine.nextOccurrence(
            spec: spec,
            timeZoneIdentifier: rule.timeZoneIdentifier,
            after: timestamp
        ))

        #expect(run.scheduledAtUnixMillis == staleOccurrence)
        #expect(run.wasMissed == true)
        #expect(run.state == .completed)
        #expect(model.snapshot.operations.automationRuns.count == 1)
        #expect(model.snapshot.domains.automations.first?.nextRunAtUnixMillis == expectedNext)
        #expect(expectedNext > timestamp)
    }

    @Test
    func persistedApprovedRunCanResumeWhilePersistedRunningRunCannotReplay() throws {
        let store = SchedulerMemoryStore()
        var clock: Int64 = 2_000_000
        let model = DesktopAppModel(store: store, now: { clock })
        let scheduled = clock + 60_000
        let automationID = try #require(makeOnceAutomation(
            in: model,
            scheduledAt: scheduled,
            name: "Recover local notification",
            authority: .localOnly,
            policy: .skip
        ))
        #expect(model.activateAutomation(id: automationID, approvalID: nil))
        clock = scheduled
        let runID = try #require(model.claimAutomationRun(
            id: automationID,
            ownerID: "scheduler-owner",
            nowUnixMillis: clock
        ))
        let claimed = try #require(model.automationRun(id: runID))
        #expect(claimed.state == .approved)
        #expect(claimed.contractTarget != nil)
        #expect(claimed.exactTarget != nil)

        let restoredApproved = DesktopAppModel(store: store, now: { clock + 1 })
        #expect(restoredApproved.automationRun(id: runID)?.exactTarget == claimed.exactTarget)
        #expect(restoredApproved.beginApprovedAutomationRun(id: runID)?.state == .running)

        let restoredRunning = DesktopAppModel(store: store, now: { clock + 2 })
        #expect(restoredRunning.automationRun(id: runID)?.state == .running)
        #expect(restoredRunning.automationRun(id: runID)?.exactTarget == claimed.exactTarget)
        #expect(restoredRunning.beginApprovedAutomationRun(id: runID) == nil)
    }

    @Test
    func frozenAutomationWorkspaceMustStillMatchBeforeDispatch() throws {
        let store = SchedulerMemoryStore()
        var clock: Int64 = 3_000_000
        let model = DesktopAppModel(store: store, now: { clock })
        let projectID = try #require(model.createProject(
            name: "Frozen workspace",
            path: "/tmp/kaname-frozen-workspace-a",
            summary: "Fixture project"
        ))
        let scheduled = clock + 60_000
        let automationID = try #require(model.createAutomation(
            name: "Prepare a workspace review",
            schedule: "Once",
            timeZoneIdentifier: "UTC",
            actionSummary: "Review the frozen workspace without writing.",
            missedRunPolicy: .skip,
            scheduleSpec: DesktopScheduleSpec(
                frequency: .once,
                hour: 0,
                minute: 0,
                onceAtUnixMillis: scheduled
            ),
            actionKind: .conversation,
            authority: .standing,
            projectID: projectID
        ))
        let rule = try #require(model.snapshot.domains.automations.first { $0.id == automationID })
        let authorityTarget = try #require(model.automationAuthorityTarget(for: rule))
        let activationApproval = try #require(model.createApproval(
            threadID: nil,
            title: "Activate frozen workspace review",
            exactTarget: authorityTarget,
            consequence: "Runs only against the reviewed workspace contract.",
            dataLeavingDevice: "Read-only project context",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.resolveApproval(id: activationApproval, approved: true)
        #expect(model.activateAutomation(id: automationID, approvalID: activationApproval))
        clock = scheduled
        let runID = try #require(model.claimAutomationRun(
            id: automationID,
            ownerID: "scheduler-owner",
            nowUnixMillis: clock
        ))
        let run = try #require(model.automationRun(id: runID))
        #expect(run.workspacePath == "/tmp/kaname-frozen-workspace-a")
        #expect(model.automationRunContractIsCurrent(id: runID))

        let project = try #require(model.project(id: projectID))
        #expect(model.updateProject(
            id: projectID,
            name: project.name,
            path: "/tmp/kaname-frozen-workspace-b",
            summary: project.summary,
            context: project.context
        ))
        #expect(!model.automationRunContractIsCurrent(id: runID))
        #expect(model.automationRun(id: runID)?.workspacePath == "/tmp/kaname-frozen-workspace-a")
        #expect(model.automationRun(id: runID)?.contractTarget == authorityTarget)
    }

    @Test
    func leaseProtectedDispatchPersistsPreparedProviderRunAndFrozenWorkspaceFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-manual-dispatch-lease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = DesktopSchedulerLeaseStore(directory: directory)
        let competingLease = DesktopSchedulerLeaseStore(directory: directory)
        let store = SchedulerMemoryStore()
        var clock: Int64 = 4_000_000
        let model = DesktopAppModel(store: store, now: { clock })
        let projectID = try #require(model.createProject(
            name: "Prepared dispatch",
            path: "/tmp/kaname-prepared-dispatch",
            summary: "Fixture project"
        ))
        let scheduled = clock + 60_000
        let automationID = try #require(model.createAutomation(
            name: "Prepare provider run",
            schedule: "Once",
            timeZoneIdentifier: "UTC",
            actionSummary: "Prepare one durable read-only provider run.",
            missedRunPolicy: .skip,
            scheduleSpec: DesktopScheduleSpec(
                frequency: .once,
                hour: 0,
                minute: 0,
                onceAtUnixMillis: scheduled
            ),
            actionKind: .conversation,
            authority: .standing,
            projectID: projectID
        ))
        let rule = try #require(model.snapshot.domains.automations.first { $0.id == automationID })
        let authorityTarget = try #require(model.automationAuthorityTarget(for: rule))
        let activationApproval = try #require(model.createApproval(
            threadID: nil,
            title: "Activate prepared provider run",
            exactTarget: authorityTarget,
            consequence: "Prepares one provider run for the frozen workspace.",
            dataLeavingDevice: "Read-only project context",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.resolveApproval(id: activationApproval, approved: true)
        #expect(model.activateAutomation(id: automationID, approvalID: activationApproval))

        clock = scheduled
        _ = try #require(try? lease.acquire(
            ownerID: "scheduler-owner",
            nowUnixMillis: clock,
            durationMillis: 90_000
        ))
        #expect(throws: DesktopScheduleError.leaseUnavailable) {
            try competingLease.acquire(
                ownerID: "other-owner",
                nowUnixMillis: clock,
                durationMillis: 90_000
            )
        }
        let automationRunID = try #require(model.claimAutomationRun(
            id: automationID,
            ownerID: "scheduler-owner",
            nowUnixMillis: clock
        ))
        let begun = try #require(model.beginApprovedAutomationRun(id: automationRunID))
        #expect(begun.ownerID == "scheduler-owner")
        #expect(model.automationRunContractIsCurrent(id: automationRunID))

        let threadID = model.createConversation(kind: .personal, projectID: projectID)
        let messageID = try #require(model.appendUserMessage(
            threadID: threadID,
            body: "Prepared from the exact approved automation occurrence."
        ))
        let providerRunID = try #require(model.enqueueProviderRun(
            threadID: threadID,
            sourceMessageID: messageID,
            usesProjectContext: false,
            workspacePathOverride: begun.workspacePath
        ))
        model.attachAutomationDispatch(
            runID: automationRunID,
            threadID: threadID,
            providerRunID: providerRunID
        )

        let restored = DesktopAppModel(store: store, now: { clock + 1 })
        let restoredAutomationRun = try #require(restored.automationRun(id: automationRunID))
        let restoredProviderRun = try #require(restored.providerRun(id: providerRunID))
        #expect(restoredAutomationRun.state == .running)
        #expect(restoredAutomationRun.threadID == threadID)
        #expect(restoredAutomationRun.providerRunID == providerRunID)
        #expect(restoredAutomationRun.workspacePath == "/tmp/kaname-prepared-dispatch")
        #expect(restoredProviderRun.state == .proposed)
        #expect(restoredProviderRun.threadID == threadID)
        #expect(restoredProviderRun.sourceMessageID == messageID)
        #expect(restoredProviderRun.usesProjectContext == false)
        #expect(restoredProviderRun.workspacePathOverride == restoredAutomationRun.workspacePath)
        #expect(restoredProviderRun.costSummary == "Pending")
        lease.release(ownerID: "scheduler-owner")
    }

    @Test
    func existingDeduplicationKeyPreventsReplayAndAdvancesTheSchedule() throws {
        let scheduled: Int64 = 1_786_309_200_000
        var snapshot = DesktopAppSnapshot.starter(now: scheduled - 1_000)
        var rule = DesktopAutomationRule(
            id: "automation-dedup",
            name: "Daily local reminder",
            schedule: "Daily at 09:30",
            timeZoneIdentifier: "Asia/Tokyo",
            actionSummary: "Show a reminder",
            missedRunPolicy: .skip,
            status: .ready,
            nextRunAtUnixMillis: scheduled,
            lastResult: "Scheduled",
            createdAtUnixMillis: scheduled - 1_000
        )
        rule.scheduleSpec = DesktopScheduleSpec(frequency: .daily, hour: 9, minute: 30)
        rule.actionKind = .notification
        rule.authority = .localOnly
        var existingRun = DesktopAutomationRunRecord(
            id: "existing-run",
            automationID: rule.id,
            scheduledAtUnixMillis: scheduled,
            startedAtUnixMillis: scheduled,
            completedAtUnixMillis: scheduled,
            state: .completed,
            detail: "Already completed.",
            evidenceArtifactIDs: []
        )
        existingRun.deduplicationKey = DesktopScheduleEngine.deduplicationKey(
            automationID: rule.id,
            scheduledAtUnixMillis: scheduled
        )
        snapshot.domains.automations = [rule]
        snapshot.operations.automationRuns = [existingRun]
        let model = DesktopAppModel(
            store: SchedulerMemoryStore(data: try JSONEncoder().encode(snapshot)),
            now: { scheduled }
        )

        #expect(model.claimAutomationRun(
            id: rule.id,
            ownerID: "scheduler-owner",
            nowUnixMillis: scheduled
        ) == nil)
        #expect(model.snapshot.operations.automationRuns == [existingRun])
        #expect((model.snapshot.domains.automations.first?.nextRunAtUnixMillis ?? 0) > scheduled)
    }

    @Test
    func calendarSourcesDeduplicateAndProposalReconciliationPersistsAnAuditReceipt() throws {
        let store = SchedulerMemoryStore()
        var clock: Int64 = 5_000
        let model = DesktopAppModel(store: store, now: { clock })
        let duplicateKeySources = [
            calendarSource(id: "old-id", name: "Old name", enabled: false),
            calendarSource(id: "retained-id", name: "Primary", enabled: true),
        ]
        model.replaceCalendarSources(duplicateKeySources)
        #expect(model.snapshot.domains.calendarSources.count == 1)
        #expect(model.snapshot.domains.calendarSources.first?.id == "retained-id")
        model.replaceCalendarSources([calendarSource(id: "retained-id", name: "Renamed", enabled: false)])
        #expect(model.snapshot.domains.calendarSources.first?.displayName == "Renamed")
        #expect(model.snapshot.domains.calendarSources.first?.isEnabled == true)

        let proposalID = try #require(model.createCalendarProposal(
            accountID: "account-1",
            calendarSourceID: "retained-id",
            title: "Review Kaname",
            startAtUnixMillis: 100_000,
            durationMinutes: 45,
            timeZoneIdentifier: "Asia/Tokyo",
            recurrence: "weekly",
            mutationKind: .update,
            eventExternalID: "event-1",
            eventRevision: "revision-1",
            recurrenceScope: "thisEvent"
        ))
        let exactTarget = "google-calendar:account-1:primary:update:sha256=fixture"
        model.prepareCalendarProposal(id: proposalID, exactTarget: exactTarget)
        let approvalID = try #require(model.createApproval(
            threadID: nil,
            title: "Update calendar event",
            exactTarget: exactTarget,
            consequence: "Updates one selected occurrence.",
            dataLeavingDevice: "Event title and time",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.attachCalendarApproval(proposalID: proposalID, approvalID: approvalID)
        model.resolveApproval(id: approvalID, approved: true)
        clock += 1
        model.reconcileCalendarProposal(
            id: proposalID,
            state: .reconciled,
            receipt: "Remote revision revision-2 matched the approved event."
        )

        let restored = DesktopAppModel(store: store, now: { clock + 1 })
        let proposal = try #require(restored.snapshot.domains.calendarProposals.first { $0.id == proposalID })
        #expect(proposal.status == .ready)
        #expect(proposal.approvalID == approvalID)
        #expect(proposal.exactTarget == exactTarget)
        #expect(proposal.remoteReceipt == "Remote revision revision-2 matched the approved event.")
        #expect(proposal.reconciledAtUnixMillis == clock)
        #expect(restored.snapshot.operations.audit.last?.domain == "calendar")
        #expect(restored.snapshot.operations.audit.last?.state == .reconciled)
        #expect(restored.snapshot.operations.audit.last?.target == exactTarget)
    }

    @Test
    func calendarMutationExecutionAndReconciliationPhasesRemainDurable() throws {
        let store = SchedulerMemoryStore()
        let clock: Int64 = 6_000
        let model = DesktopAppModel(store: store, now: { clock })
        let proposalID = try #require(model.createCalendarProposal(
            accountID: "account-1",
            calendarSourceID: "calendar-1",
            title: "Durable calendar phase",
            startAtUnixMillis: 100_000,
            durationMinutes: 30,
            timeZoneIdentifier: "Asia/Tokyo",
            recurrence: "weekly",
            isAllDay: true,
            mutationKind: .update,
            eventExternalID: "event-1",
            eventRevision: "event-revision-1",
            seriesMasterRevision: "master-revision-1",
            seriesMasterRecurrence: ["RRULE:FREQ=WEEKLY;UNTIL=20261231T000000Z"],
            recurrenceScope: "thisAndFuture"
        ))
        #expect(model.snapshot.domains.calendarProposals.first { $0.id == proposalID }?.mutationPhase == "prepared")
        #expect(model.snapshot.domains.calendarProposals.first { $0.id == proposalID }?.isAllDay == true)
        let exactTarget = "google-calendar:account-1:primary:update:\(proposalID):sha256=fixture"
        model.prepareCalendarProposal(id: proposalID, exactTarget: exactTarget)
        let approvalID = try #require(model.createApproval(
            threadID: nil,
            title: "Run durable calendar mutation",
            exactTarget: exactTarget,
            consequence: "Updates the reviewed recurring event.",
            dataLeavingDevice: "Event fields and bound revisions",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.attachCalendarApproval(proposalID: proposalID, approvalID: approvalID)
        model.resolveApproval(id: approvalID, approved: true)
        #expect(model.beginCalendarProposalExecution(id: proposalID))
        model.recordCalendarMutationPhase(id: proposalID, phase: "dispatching")

        let dispatching = DesktopAppModel(store: store, now: { clock + 1 })
        #expect(dispatching.snapshot.domains.calendarProposals.first { $0.id == proposalID }?.status == .running)
        #expect(dispatching.snapshot.domains.calendarProposals.first { $0.id == proposalID }?.mutationPhase == "dispatching")
        dispatching.recordCalendarMutationPhase(id: proposalID, phase: "primaryApplied")

        let partialClock = clock + 2
        let partiallyApplied = DesktopAppModel(store: store, now: { partialClock })
        #expect(partiallyApplied.snapshot.domains.calendarProposals.first { $0.id == proposalID }?.status == .running)
        #expect(partiallyApplied.snapshot.domains.calendarProposals.first { $0.id == proposalID }?.mutationPhase == "primaryApplied")
        partiallyApplied.recordCalendarMutationPhase(id: proposalID, phase: "reconciling")
        partiallyApplied.recordCalendarMutationPhase(id: proposalID, phase: "complete")
        partiallyApplied.reconcileCalendarProposal(
            id: proposalID,
            state: .reconciled,
            receipt: "Both recurrence sides matched the approved revisions."
        )

        let reconciled = DesktopAppModel(store: store, now: { partialClock + 1 })
        let proposal = try #require(reconciled.snapshot.domains.calendarProposals.first { $0.id == proposalID })
        #expect(proposal.status == .ready)
        #expect(proposal.mutationPhase == "complete")
        #expect(proposal.remoteReceipt == "Both recurrence sides matched the approved revisions.")
        #expect(proposal.reconciledAtUnixMillis == partialClock)
        #expect(reconciled.snapshot.operations.audit.last?.domain == "calendar")
        #expect(reconciled.snapshot.operations.audit.last?.state == .reconciled)
    }

    @Test
    func failedPersistencePreventsClaimBeginEnqueueAndDispatchStateTransitions() throws {
        var clock: Int64 = 7_000
        let healthy = DesktopAppModel(store: SchedulerMemoryStore(), now: { clock })
        let scheduled = clock + 60_000
        let automationID = try #require(makeOnceAutomation(
            in: healthy,
            scheduledAt: scheduled,
            name: "Persistence atomicity",
            authority: .localOnly,
            policy: .skip
        ))
        #expect(healthy.activateAutomation(id: automationID, approvalID: nil))
        let readyRule = try #require(healthy.snapshot.domains.automations.first { $0.id == automationID })
        let readyData = try JSONEncoder().encode(healthy.snapshot)
        let failedClaim = DesktopAppModel(
            store: FailingSaveDesktopStateStore(data: readyData),
            now: { scheduled }
        )

        #expect(failedClaim.claimAutomationRun(
            id: automationID,
            ownerID: "scheduler-owner",
            nowUnixMillis: scheduled
        ) == nil)
        #expect(failedClaim.snapshot.operations.automationRuns.isEmpty)
        #expect(failedClaim.snapshot.domains.automations.first { $0.id == automationID }?.status == .ready)
        #expect(failedClaim.snapshot.domains.automations.first { $0.id == automationID }?.nextRunAtUnixMillis == readyRule.nextRunAtUnixMillis)
        #expect(failedClaim.persistenceError != nil)

        clock = scheduled
        let automationRunID = try #require(healthy.claimAutomationRun(
            id: automationID,
            ownerID: "scheduler-owner",
            nowUnixMillis: scheduled
        ))
        let approvedData = try JSONEncoder().encode(healthy.snapshot)
        let failedBegin = DesktopAppModel(
            store: FailingSaveDesktopStateStore(data: approvedData),
            now: { scheduled + 1 }
        )
        let claimedStart = failedBegin.automationRun(id: automationRunID)?.startedAtUnixMillis
        #expect(failedBegin.beginApprovedAutomationRun(id: automationRunID) == nil)
        #expect(failedBegin.automationRun(id: automationRunID)?.state == .approved)
        #expect(failedBegin.automationRun(id: automationRunID)?.startedAtUnixMillis == claimedStart)
        #expect(failedBegin.persistenceError != nil)

        let threadID = healthy.createConversation(kind: .personal, projectID: nil)
        let messageID = try #require(healthy.appendUserMessage(
            threadID: threadID,
            body: "Do not queue this when the durable save fails."
        ))
        let providerRunID = try #require(healthy.enqueueProviderRun(
            threadID: threadID,
            sourceMessageID: messageID,
            usesProjectContext: false
        ))
        let preparedData = try JSONEncoder().encode(healthy.snapshot)
        let failedEnqueue = DesktopAppModel(
            store: FailingSaveDesktopStateStore(data: preparedData),
            now: { scheduled + 2 }
        )
        let providerCount = failedEnqueue.snapshot.operations.providerRuns.count
        #expect(failedEnqueue.enqueueProviderRun(
            threadID: threadID,
            sourceMessageID: messageID,
            usesProjectContext: false
        ) == nil)
        #expect(failedEnqueue.snapshot.operations.providerRuns.count == providerCount)
        #expect(failedEnqueue.persistenceError != nil)

        let failedDispatch = DesktopAppModel(
            store: FailingSaveDesktopStateStore(data: preparedData),
            now: { scheduled + 3 }
        )
        #expect(!failedDispatch.attachAutomationDispatch(
            runID: automationRunID,
            threadID: threadID,
            providerRunID: providerRunID
        ))
        #expect(failedDispatch.automationRun(id: automationRunID)?.threadID == nil)
        #expect(failedDispatch.automationRun(id: automationRunID)?.providerRunID == nil)
        #expect(failedDispatch.automationRun(id: automationRunID)?.state == .approved)
        #expect(failedDispatch.persistenceError != nil)
    }

    @Test
    func frozenCalendarOccurrenceAndEditedDraftRemainSeparateAcrossRestart() throws {
        let store = SchedulerMemoryStore()
        let model = DesktopAppModel(store: store, now: { 8_000 })
        let originalStart: Int64 = 1_786_309_200_000
        let originalEnd = originalStart + 45 * 60 * 1_000
        let editedStart = originalStart + 2 * 60 * 60 * 1_000
        let masterStart = originalStart - 7 * 86_400_000
        let proposalID = try #require(model.createCalendarProposal(
            accountID: "account-1",
            calendarSourceID: "calendar-1",
            title: "Edited occurrence title",
            startAtUnixMillis: editedStart,
            durationMinutes: 90,
            timeZoneIdentifier: "Asia/Tokyo",
            recurrence: "RRULE:FREQ=WEEKLY;BYDAY=TU",
            isAllDay: false,
            mutationKind: .update,
            eventExternalID: "occurrence-1",
            seriesMasterExternalID: "series-1",
            eventRevision: "occurrence-revision-1",
            originalTitle: "Original occurrence title",
            originalStartAtUnixMillis: originalStart,
            originalEndAtUnixMillis: originalEnd,
            originalTimeZoneIdentifier: "Asia/Tokyo",
            originalRecurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO"],
            originalIsAllDay: true,
            seriesMasterRevision: "master-revision-1",
            seriesMasterRecurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261231T000000Z"],
            seriesMasterStartAtUnixMillis: masterStart,
            recurrenceScope: "thisAndFuture"
        ))

        let restored = DesktopAppModel(store: store, now: { 8_001 })
        let proposal = try #require(restored.snapshot.domains.calendarProposals.first { $0.id == proposalID })
        #expect(proposal.title == "Edited occurrence title")
        #expect(proposal.startAtUnixMillis == editedStart)
        #expect(proposal.durationMinutes == 90)
        #expect(proposal.recurrence == "RRULE:FREQ=WEEKLY;BYDAY=TU")
        #expect(proposal.isAllDay == false)
        #expect(proposal.originalTitle == "Original occurrence title")
        #expect(proposal.originalStartAtUnixMillis == originalStart)
        #expect(proposal.originalEndAtUnixMillis == originalEnd)
        #expect(proposal.originalTimeZoneIdentifier == "Asia/Tokyo")
        #expect(proposal.originalRecurrence == ["RRULE:FREQ=WEEKLY;BYDAY=MO"])
        #expect(proposal.originalIsAllDay == true)
        #expect(proposal.eventExternalID == "occurrence-1")
        #expect(proposal.seriesMasterExternalID == "series-1")
        #expect(proposal.eventRevision == "occurrence-revision-1")
        #expect(proposal.seriesMasterRevision == "master-revision-1")
        #expect(proposal.seriesMasterRecurrence == ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261231T000000Z"])
        #expect(proposal.seriesMasterStartAtUnixMillis == masterStart)
    }

    private func makeOnceAutomation(
        in model: DesktopAppModel,
        scheduledAt: Int64,
        name: String,
        authority: DesktopAutomationAuthority,
        policy: DesktopAutomationRule.MissedRunPolicy
    ) -> String? {
        model.createAutomation(
            name: name,
            schedule: "Once",
            timeZoneIdentifier: "UTC",
            actionSummary: "Show a local notification",
            missedRunPolicy: policy,
            scheduleSpec: DesktopScheduleSpec(
                frequency: .once,
                hour: 0,
                minute: 0,
                onceAtUnixMillis: scheduledAt
            ),
            actionKind: .notification,
            authority: authority
        )
    }

    private func calendarSource(id: String, name: String, enabled: Bool) -> DesktopCalendarSourceRecord {
        DesktopCalendarSourceRecord(
            id: id,
            accountID: "account-1",
            externalIdentifier: "primary",
            provider: .google,
            displayName: name,
            ownerIdentity: "calendar@example.test",
            accessLevel: "owner",
            isPrimary: true,
            isEnabled: enabled
        )
    }

    private func calendar(in timeZone: TimeZone) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = timeZone
        return value
    }

    private func localMillis(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        timeZone: TimeZone
    ) throws -> Int64 {
        let date = try #require(calendar(in: timeZone).date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
}

private final class SchedulerMemoryStore: DesktopStateStoring {
    private var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}

private final class FailingSaveDesktopStateStore: DesktopStateStoring {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func load() -> Data? { data }

    func save(_ data: Data) throws {
        throw Failure.expected
    }

    private enum Failure: Error {
        case expected
    }
}
