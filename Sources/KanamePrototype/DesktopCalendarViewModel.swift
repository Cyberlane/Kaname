import Foundation
import KanameConnectivity
import KanameDesktop

@MainActor
final class DesktopCalendarViewModel: ObservableObject {
    @Published private(set) var events: [CalendarEventSnapshot] = []
    @Published private(set) var failedSources: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var activeProposalID: String?

    private let google: NativeGoogleIntegrationService
    private let apple = AppleCalendarIntegrationService()

    init(environment: KanameDesktopEnvironment = .current) {
        google = NativeGoogleIntegrationService(
            rootDirectory: environment.googleDirectory,
            keychainService: environment.googleKeychainService
        )
    }

    func selectProposal(_ id: String) {
        activeProposalID = id
    }

    func refresh(
        sources: [DesktopCalendarSourceRecord],
        googleAccounts: [NativeGoogleAccountSnapshot]
    ) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            var discovered: [CalendarEventSnapshot] = []
            var failures: [String] = []
            let start = Calendar.current.startOfDay(for: .now.addingTimeInterval(-86_400))
            let end = start.addingTimeInterval(86_400 * 91)
            for source in sources where source.isEnabled {
                do {
                    switch source.provider {
                    case .google:
                        guard let account = googleAccounts.first(where: { $0.identity == source.ownerIdentity }) else {
                            failures.append(source.displayName)
                            continue
                        }
                        discovered.append(contentsOf: try await google.listCalendarEvents(
                            accountID: account.id,
                            calendarID: source.externalIdentifier,
                            from: start,
                            through: end
                        ))
                    case .apple:
                        discovered.append(contentsOf: try apple.listEvents(
                            accountID: source.accountID,
                            accountIdentity: source.ownerIdentity,
                            calendarID: source.externalIdentifier,
                            from: start,
                            through: end
                        ))
                    }
                } catch { failures.append(source.displayName) }
            }
            events = CalendarWorkCodec.deduplicated(discovered)
            failedSources = failures
            message = failures.isEmpty
                ? "Reconciled \(events.count) event(s) across \(sources.filter(\.isEnabled).count) enabled calendar(s)."
                : "Reconciled \(events.count) event(s); \(failures.count) calendar source(s) remain available for retry."
            isBusy = false
        }
    }

    func proposeCreate(
        model: DesktopAppModel,
        proposal: DesktopCalendarProposal,
        source: DesktopCalendarSourceRecord,
        googleAccounts: [NativeGoogleAccountSnapshot]
    ) {
        let mutation = CalendarMutation.create(draft(proposal))
        prepare(model: model, proposalID: proposal.id, source: source, mutation: mutation, googleAccounts: googleAccounts)
    }

    func proposeChange(
        model: DesktopAppModel,
        event: CalendarEventSnapshot,
        source: DesktopCalendarSourceRecord,
        kind: DesktopCalendarProposal.MutationKind,
        scope: CalendarRecurrenceScope,
        draft changedDraft: CalendarEventDraft? = nil,
        googleAccounts: [NativeGoogleAccountSnapshot]
    ) {
        let updated = changedDraft ?? draft(event)
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                var boundEvent = event
                if source.provider == .google, event.recurringEventID != nil, scope != .thisEvent {
                    guard let account = googleAccounts.first(where: { $0.identity == source.ownerIdentity }) else {
                        throw CalendarWorkError.accountNotFound
                    }
                    guard account.supportsCalendarEventWrites else { throw CalendarWorkError.authorizationUpgradeRequired }
                    let master = try await google.googleCalendarEvent(
                        accountID: account.id,
                        calendarID: source.externalIdentifier,
                        eventID: event.recurringEventID!
                    )
                    boundEvent.seriesMasterRevision = master.revision
                    boundEvent.seriesMasterRecurrence = master.recurrence
                    boundEvent.seriesMasterStartAtUnixMillis = master.startAtUnixMillis
                    if scope == .thisAndFuture {
                        _ = try CalendarWorkCodec.splitRecurrence(
                            master.recurrence,
                            beforeUnixMillis: event.startAtUnixMillis
                        )
                    }
                }
                guard let proposalID = model.createCalendarProposal(
                    accountID: source.accountID,
                    calendarSourceID: source.id,
                    title: updated.title,
                    startAtUnixMillis: updated.startAtUnixMillis,
                    durationMinutes: max(1, Int((updated.endAtUnixMillis - updated.startAtUnixMillis) / 60_000)),
                    timeZoneIdentifier: updated.timeZoneIdentifier,
                    recurrence: updated.recurrence,
                    isAllDay: updated.isAllDay,
                    mutationKind: kind,
                    eventExternalID: boundEvent.eventID,
                    seriesMasterExternalID: boundEvent.recurringEventID,
                    eventRevision: boundEvent.revision,
                    originalTitle: boundEvent.title,
                    originalStartAtUnixMillis: boundEvent.startAtUnixMillis,
                    originalEndAtUnixMillis: boundEvent.endAtUnixMillis,
                    originalTimeZoneIdentifier: boundEvent.timeZoneIdentifier,
                    originalRecurrence: boundEvent.recurrence,
                    originalIsAllDay: boundEvent.isAllDay,
                    seriesMasterRevision: boundEvent.seriesMasterRevision,
                    seriesMasterRecurrence: boundEvent.seriesMasterRecurrence,
                    seriesMasterStartAtUnixMillis: boundEvent.seriesMasterStartAtUnixMillis,
                    recurrenceScope: scope.rawValue
                ) else { throw CalendarWorkError.invalidEvent }
                let mutation: CalendarMutation = kind == .delete
                    ? .delete(existing: boundEvent, scope: scope)
                    : .update(existing: boundEvent, draft: updated, scope: scope)
                prepare(model: model, proposalID: proposalID, source: source, mutation: mutation, googleAccounts: googleAccounts)
            } catch { message = error.localizedDescription }
            isBusy = false
        }
    }

    func requestApproval(model: DesktopAppModel) {
        guard let proposal = activeProposal(model: model),
              let target = proposal.exactTarget,
              proposal.approvalID == nil else { return }
        let approvalID = model.createApproval(
            threadID: nil,
            title: "\(proposal.mutationKind?.label ?? "Create") calendar event",
            exactTarget: target,
            consequence: preview(proposal),
            dataLeavingDevice: "Resolved calendar, title, start, end, time zone, recurrence, and event revision",
            reversible: proposal.mutationKind != .delete,
            expiresAtUnixMillis: nil
        )
        if let approvalID { model.attachCalendarApproval(proposalID: proposal.id, approvalID: approvalID) }
        message = "The exact calendar action is ready in Inbox."
    }

    func prepareAgain(
        model: DesktopAppModel,
        proposal: DesktopCalendarProposal,
        source: DesktopCalendarSourceRecord,
        googleAccounts: [NativeGoogleAccountSnapshot]
    ) {
        guard let mutation = mutation(proposal, source: source) else {
            message = proposal.mutationKind == .create
                ? "The local event proposal is incomplete."
                : "Refresh events before reviewing this change again."
            return
        }
        prepare(model: model, proposalID: proposal.id, source: source, mutation: mutation, googleAccounts: googleAccounts)
    }

    func execute(
        model: DesktopAppModel,
        sources: [DesktopCalendarSourceRecord],
        googleAccounts: [NativeGoogleAccountSnapshot]
    ) {
        guard !isBusy,
              let proposal = activeProposal(model: model),
              let approvalID = proposal.approvalID,
              let target = proposal.exactTarget,
              let source = sources.first(where: { $0.id == proposal.calendarSourceID }),
              let mutation = mutation(proposal, source: source),
              model.beginCalendarProposalExecution(id: proposal.id) else {
            message = model.snapshot.preferences.safeMode
                ? "Safe mode is on. Turn it off in Privacy & Safety before changing a calendar."
                : "Approve this exact calendar action in Inbox first."
            return
        }
        isBusy = true
        Task {
            do {
                let grant = CalendarMutationGrant.approved(
                    operationID: proposal.id,
                    approvalID: approvalID,
                    exactTarget: target,
                    resumePhase: CalendarMutationPhase(rawValue: proposal.mutationPhase ?? "") ?? .prepared
                )
                let receipt: CalendarMutationReceipt
                switch source.provider {
                case .google:
                    guard let account = googleAccounts.first(where: { $0.identity == source.ownerIdentity }) else {
                        throw CalendarWorkError.accountNotFound
                    }
                    receipt = try await google.mutateGoogleCalendar(
                        accountID: account.id,
                        calendarID: source.externalIdentifier,
                        mutation: mutation,
                        grant: grant,
                        progress: { phase in
                            await MainActor.run {
                                model.recordCalendarMutationPhase(id: proposal.id, phase: phase.rawValue)
                            }
                        }
                    )
                case .apple:
                    model.recordCalendarMutationPhase(id: proposal.id, phase: CalendarMutationPhase.dispatching.rawValue)
                    receipt = try apple.mutate(
                        accountID: source.accountID,
                        accountIdentity: source.ownerIdentity,
                        calendarID: source.externalIdentifier,
                        mutation: mutation,
                        grant: grant
                    )
                }
                model.reconcileCalendarProposal(id: proposal.id, state: .reconciled, receipt: receipt.detail)
                message = receipt.detail
                isBusy = false
                refresh(sources: sources, googleAccounts: googleAccounts)
                return
            } catch {
                let phase = model.snapshot.domains.calendarProposals.first(where: { $0.id == proposal.id })?.mutationPhase
                if phase == nil || phase == CalendarMutationPhase.prepared.rawValue {
                    model.reconcileCalendarProposal(id: proposal.id, state: .failed, receipt: error.localizedDescription)
                } else {
                    model.recordCalendarMutationUncertain(id: proposal.id, detail: error.localizedDescription)
                }
                message = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func prepare(
        model: DesktopAppModel,
        proposalID: String,
        source: DesktopCalendarSourceRecord,
        mutation: CalendarMutation,
        googleAccounts: [NativeGoogleAccountSnapshot]
    ) {
        do {
            let target: String
            switch source.provider {
            case .google:
                guard let account = googleAccounts.first(where: { $0.identity == source.ownerIdentity }) else {
                    throw CalendarWorkError.accountNotFound
                }
                target = try NativeGoogleIntegrationService.googleCalendarTarget(
                    accountID: account.id,
                    calendarID: source.externalIdentifier,
                    operationID: proposalID,
                    mutation: mutation
                )
            case .apple:
                target = try AppleCalendarIntegrationService.mutationTarget(
                    accountID: source.accountID,
                    calendarID: source.externalIdentifier,
                    operationID: proposalID,
                    mutation: mutation
                )
            }
            activeProposalID = proposalID
            model.prepareCalendarProposal(id: proposalID, exactTarget: target)
            message = "Review the exact calendar, event revision, recurrence scope, and consequence."
        } catch { message = error.localizedDescription }
    }

    private func mutation(
        _ proposal: DesktopCalendarProposal,
        source: DesktopCalendarSourceRecord? = nil
    ) -> CalendarMutation? {
        let frozenEvent: CalendarEventSnapshot? = {
            guard let source,
                  let eventID = proposal.eventExternalID,
                  let revision = proposal.eventRevision,
                  let originalTitle = proposal.originalTitle,
                  let originalStart = proposal.originalStartAtUnixMillis,
                  let originalEnd = proposal.originalEndAtUnixMillis,
                  let originalTimeZone = proposal.originalTimeZoneIdentifier,
                  let originalRecurrence = proposal.originalRecurrence,
                  let originalIsAllDay = proposal.originalIsAllDay else { return nil }
            return CalendarEventSnapshot.restored(
                provider: CalendarWorkProvider(rawValue: source.provider.rawValue) ?? .apple,
                accountID: source.accountID,
                accountIdentity: source.ownerIdentity,
                calendarID: source.externalIdentifier,
                eventID: eventID,
                recurringEventID: proposal.seriesMasterExternalID,
                title: originalTitle,
                startAtUnixMillis: originalStart,
                endAtUnixMillis: originalEnd,
                timeZoneIdentifier: originalTimeZone,
                recurrence: originalRecurrence,
                revision: revision,
                canEdit: true,
                isAllDay: originalIsAllDay,
                seriesMasterRevision: proposal.seriesMasterRevision,
                seriesMasterRecurrence: proposal.seriesMasterRecurrence,
                seriesMasterStartAtUnixMillis: proposal.seriesMasterStartAtUnixMillis
            )
        }()
        var boundEvent = frozenEvent
        boundEvent?.seriesMasterRevision = proposal.seriesMasterRevision
        boundEvent?.seriesMasterRecurrence = proposal.seriesMasterRecurrence
        boundEvent?.seriesMasterStartAtUnixMillis = proposal.seriesMasterStartAtUnixMillis
        switch proposal.mutationKind ?? .create {
        case .create: return .create(draft(proposal))
        case .update:
            guard let boundEvent, let scope = proposal.recurrenceScope.flatMap(CalendarRecurrenceScope.init(rawValue:)) else { return nil }
            return .update(existing: boundEvent, draft: draft(proposal), scope: scope)
        case .delete:
            guard let boundEvent, let scope = proposal.recurrenceScope.flatMap(CalendarRecurrenceScope.init(rawValue:)) else { return nil }
            return .delete(existing: boundEvent, scope: scope)
        }
    }

    private func draft(_ proposal: DesktopCalendarProposal) -> CalendarEventDraft {
        let factory = proposal.isAllDay == true ? CalendarEventDraft.allDay : CalendarEventDraft.timed
        return factory(
            proposal.title,
            proposal.startAtUnixMillis,
            proposal.startAtUnixMillis + Int64(proposal.durationMinutes) * 60_000,
            proposal.timeZoneIdentifier,
            proposal.recurrence
        )
    }

    private func draft(_ event: CalendarEventSnapshot) -> CalendarEventDraft {
        let factory = event.isAllDay ? CalendarEventDraft.allDay : CalendarEventDraft.timed
        return factory(
            event.title,
            event.startAtUnixMillis,
            event.endAtUnixMillis,
            event.timeZoneIdentifier,
            event.recurrence.first ?? (event.recurringEventID == nil ? "Does not repeat" : "Recurring")
        )
    }

    private func activeProposal(model: DesktopAppModel) -> DesktopCalendarProposal? {
        activeProposalID.flatMap { id in model.snapshot.domains.calendarProposals.first { $0.id == id } }
    }

    private func preview(_ proposal: DesktopCalendarProposal) -> String {
        let scope = proposal.recurrenceScope.flatMap(CalendarRecurrenceScope.init(rawValue:))?.label
        return "\(proposal.mutationKind?.label ?? "Create") “\(proposal.title)” in the selected calendar at \(proposal.startAtUnixMillis).\(scope.map { " Scope: \($0)." } ?? "")"
    }
}
