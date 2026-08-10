#if canImport(EventKit)
import CryptoKit
import EventKit
import Foundation

public enum AppleCalendarAccessState: String, Equatable, Sendable {
    case notRequested
    case denied
    case restricted
    case writeOnly
    case ready
    case unavailable
}

public struct AppleCalendarSourceSnapshot: Equatable, Sendable {
    public let externalIdentifier: String
    public let name: String
    public let sourceName: String
    public let allowsChanges: Bool
}

@MainActor
public final class AppleCalendarIntegrationService {
    private let store: EKEventStore

    public init() {
        store = EKEventStore()
    }

    public var accessState: AppleCalendarAccessState {
        Self.accessState(for: EKEventStore.authorizationStatus(for: .event))
    }

    public func requestAccessAndListCalendars() async throws -> [AppleCalendarSourceSnapshot] {
        let granted: Bool
        if #available(macOS 14.0, iOS 17.0, *) {
            granted = try await store.requestFullAccessToEvents()
        } else {
            granted = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { allowed, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: allowed)
                    }
                }
            }
        }
        guard granted else { throw CalendarWorkError.calendarAccessUnavailable }
        return calendarSnapshots()
    }

    public func listCalendarsIfAuthorized() -> [AppleCalendarSourceSnapshot] {
        guard accessState == .ready else { return [] }
        return calendarSnapshots()
    }

    public static func mutationTarget(
        accountID: String,
        calendarID: String,
        operationID: String,
        mutation: CalendarMutation
    ) throws -> String {
        return try ProviderActionTarget.sha256(
            scheme: "apple-calendar",
            components: [accountID, calendarID, mutation.canonicalName, operationID],
            payload: CalendarWorkCodec.canonicalPayload(mutation)
        )
    }

    public func listEvents(
        accountID: String,
        accountIdentity: String,
        calendarID: String,
        from start: Date,
        through end: Date
    ) throws -> [CalendarEventSnapshot] {
        guard accessState == .ready else { throw CalendarWorkError.calendarAccessUnavailable }
        let calendar = try mutableCalendar(id: calendarID, requireWrite: false)
        return CalendarWorkCodec.deduplicated(store.events(
            matching: store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        ).map { eventSnapshot($0, accountID: accountID, accountIdentity: accountIdentity) })
    }

    public func mutate(
        accountID: String,
        accountIdentity: String,
        calendarID: String,
        mutation: CalendarMutation,
        grant: CalendarMutationGrant
    ) throws -> CalendarMutationReceipt {
        let target = try Self.mutationTarget(
            accountID: accountID,
            calendarID: calendarID,
            operationID: grant.operationID,
            mutation: mutation
        )
        guard grant.exactTarget == target else { throw CalendarWorkError.approvalMismatch }
        let calendar = try mutableCalendar(id: calendarID, requireWrite: true)
        switch mutation {
        case let .create(draft):
            let marker = idempotencyMarker(exactTarget: target)
            let lookupStart = Date(timeIntervalSince1970: Double(draft.startAtUnixMillis) / 1_000).addingTimeInterval(-86_400)
            let lookupEnd = Date(timeIntervalSince1970: Double(draft.endAtUnixMillis) / 1_000).addingTimeInterval(86_400)
            if let existing = store.events(matching: store.predicateForEvents(withStart: lookupStart, end: lookupEnd, calendars: [calendar]))
                .first(where: { $0.url == marker }) {
                let reconciled = eventSnapshot(existing, accountID: accountID, accountIdentity: accountIdentity)
                guard matchesApprovedFields(reconciled, event: existing, draft: draft, verifyRecurrence: true) else {
                    throw CalendarWorkError.reconciliationFailed
                }
                return CalendarMutationReceipt(
                    approvalID: grant.approvalID,
                    exactTarget: target,
                    reconciledEvent: reconciled,
                    detail: "Found the previously created Apple Calendar event and reconciled its local revision without creating a duplicate."
                )
            }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            applyFields(draft, to: event)
            try applyRecurrence(draft.recurrence, to: event)
            event.url = marker
            try store.save(event, span: .thisEvent, commit: true)
            guard let reconciled = store.event(withIdentifier: event.eventIdentifier) else {
                throw CalendarWorkError.reconciliationFailed
            }
            let snapshot = eventSnapshot(reconciled, accountID: accountID, accountIdentity: accountIdentity)
            guard matchesApprovedFields(snapshot, event: reconciled, draft: draft, verifyRecurrence: true) else {
                throw CalendarWorkError.reconciliationFailed
            }
            return CalendarMutationReceipt(
                approvalID: grant.approvalID,
                exactTarget: target,
                reconciledEvent: snapshot,
                detail: "Created the Apple Calendar event and re-read its local revision."
            )
        case let .update(existing, draft, scope):
            guard scope != .entireSeries else { throw CalendarWorkError.recurrenceSplitUnavailable }
            guard let event = store.event(withIdentifier: existing.eventID) else { throw CalendarWorkError.revisionConflict }
            if revision(for: event) != existing.revision {
                let current = eventSnapshot(event, accountID: accountID, accountIdentity: accountIdentity)
                guard matchesApprovedUpdate(current, event: event, draft: draft, existing: existing) else {
                    throw CalendarWorkError.revisionConflict
                }
                return CalendarMutationReceipt(
                    approvalID: grant.approvalID,
                    exactTarget: target,
                    reconciledEvent: current,
                    detail: "Recovered the previously applied Apple Calendar update and verified every approved field without applying it twice."
                )
            }
            applyFields(draft, to: event)
            try store.save(event, span: eventSpan(scope), commit: true)
            guard let reconciled = store.event(withIdentifier: event.eventIdentifier) else {
                throw CalendarWorkError.reconciliationFailed
            }
            let snapshot = eventSnapshot(reconciled, accountID: accountID, accountIdentity: accountIdentity)
            guard matchesApprovedUpdate(snapshot, event: reconciled, draft: draft, existing: existing) else {
                throw CalendarWorkError.reconciliationFailed
            }
            return CalendarMutationReceipt(
                approvalID: grant.approvalID,
                exactTarget: target,
                reconciledEvent: snapshot,
                detail: "Updated the selected recurrence scope and re-read the Apple Calendar event."
            )
        case let .delete(existing, scope):
            guard scope != .entireSeries else { throw CalendarWorkError.recurrenceSplitUnavailable }
            guard let event = store.event(withIdentifier: existing.eventID) else {
                try verifyDeletedScope(existing, scope: scope, calendar: calendar)
                return CalendarMutationReceipt(
                    approvalID: grant.approvalID,
                    exactTarget: target,
                    reconciledEvent: nil,
                    detail: "Recovered the previously applied Apple Calendar deletion and verified the approved scope remains absent."
                )
            }
            guard revision(for: event) == existing.revision else { throw CalendarWorkError.revisionConflict }
            try store.remove(event, span: eventSpan(scope), commit: true)
            try verifyDeletedScope(existing, scope: scope, calendar: calendar)
            return CalendarMutationReceipt(
                approvalID: grant.approvalID,
                exactTarget: target,
                reconciledEvent: nil,
                detail: "Removed the selected Apple Calendar recurrence scope and reconciled the event store."
            )
        }
    }

    private func calendarSnapshots() -> [AppleCalendarSourceSnapshot] {
        return store.calendars(for: .event).map {
            AppleCalendarSourceSnapshot(
                externalIdentifier: $0.calendarIdentifier,
                name: $0.title,
                sourceName: $0.source.title,
                allowsChanges: $0.allowsContentModifications
            )
        }.sorted {
            "\($0.sourceName)|\($0.name)".localizedCaseInsensitiveCompare(
                "\($1.sourceName)|\($1.name)"
            ) == .orderedAscending
        }
    }

    private func mutableCalendar(id: String, requireWrite: Bool) throws -> EKCalendar {
        guard accessState == .ready else { throw CalendarWorkError.calendarAccessUnavailable }
        guard let calendar = store.calendar(withIdentifier: id),
              !requireWrite || calendar.allowsContentModifications else { throw CalendarWorkError.invalidEvent }
        return calendar
    }

    private func applyFields(_ draft: CalendarEventDraft, to event: EKEvent) {
        event.title = draft.title
        event.startDate = Date(timeIntervalSince1970: Double(draft.startAtUnixMillis) / 1_000)
        event.endDate = Date(timeIntervalSince1970: Double(draft.endAtUnixMillis) / 1_000)
        event.timeZone = TimeZone(identifier: draft.timeZoneIdentifier)
        event.isAllDay = draft.isAllDay
    }

    private func applyRecurrence(_ recurrence: String, to event: EKEvent) throws {
        switch try recurrenceFrequency(recurrence) {
        case .none:
            event.recurrenceRules = nil
        case let .some(frequency):
            event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil)]
        }
    }

    private func recurrenceFrequency(_ recurrence: String) throws -> EKRecurrenceFrequency? {
        switch recurrence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "does not repeat": nil
        case "daily": .daily
        case "weekly": .weekly
        case "monthly": .monthly
        default: throw CalendarWorkError.invalidEvent
        }
    }

    private func matchesApprovedFields(
        _ snapshot: CalendarEventSnapshot,
        event: EKEvent,
        draft: CalendarEventDraft,
        verifyRecurrence: Bool
    ) -> Bool {
        guard CalendarWorkCodec.matches(snapshot, draft: draft), snapshot.isAllDay == draft.isAllDay else {
            return false
        }
        guard verifyRecurrence else { return true }
        let expected: EKRecurrenceFrequency?
        do {
            expected = try recurrenceFrequency(draft.recurrence)
        } catch {
            return false
        }
        let rules = event.recurrenceRules ?? []
        if let expected {
            return rules.count == 1 && rules[0].frequency == expected && rules[0].interval == 1
        }
        return rules.isEmpty
    }

    private func matchingFutureOccurrences(of existing: CalendarEventSnapshot, in calendar: EKCalendar) -> Bool {
        let lowerBound = Date(timeIntervalSince1970: Double(existing.startAtUnixMillis) / 1_000)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: existing.timeZoneIdentifier) ?? .autoupdatingCurrent
        guard let upperBound = gregorian.date(byAdding: .year, value: 10, to: lowerBound) else { return true }
        let events = store.events(matching: store.predicateForEvents(
            withStart: lowerBound,
            end: upperBound,
            calendars: [calendar]
        ))
        guard let seriesIdentifier = existing.recurringEventID else {
            return events.contains { $0.eventIdentifier == existing.eventID && $0.startDate >= lowerBound }
        }
        return events.contains {
            $0.calendarItemExternalIdentifier == seriesIdentifier && $0.startDate >= lowerBound
        }
    }

    private func matchesApprovedUpdate(
        _ snapshot: CalendarEventSnapshot,
        event: EKEvent,
        draft: CalendarEventDraft,
        existing: CalendarEventSnapshot
    ) -> Bool {
        matchesApprovedFields(snapshot, event: event, draft: draft, verifyRecurrence: false)
            && CalendarWorkCodec.recurrenceEquals(snapshot.recurrence, existing.recurrence)
    }

    private func verifyDeletedScope(
        _ existing: CalendarEventSnapshot,
        scope: CalendarRecurrenceScope,
        calendar: EKCalendar
    ) throws {
        switch scope {
        case .thisEvent:
            guard store.event(withIdentifier: existing.eventID) == nil else {
                throw CalendarWorkError.reconciliationFailed
            }
        case .thisAndFuture:
            guard !matchingFutureOccurrences(of: existing, in: calendar) else {
                throw CalendarWorkError.reconciliationFailed
            }
        case .entireSeries:
            throw CalendarWorkError.recurrenceSplitUnavailable
        }
    }

    private func eventSpan(_ scope: CalendarRecurrenceScope) -> EKSpan {
        scope == .thisEvent ? .thisEvent : .futureEvents
    }

    private func idempotencyMarker(exactTarget: String) -> URL {
        let digest = SHA256.hash(data: Data(exactTarget.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "kaname://calendar-action/\(digest)")!
    }

    private func eventSnapshot(
        _ event: EKEvent,
        accountID: String,
        accountIdentity: String
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            provider: .apple,
            accountID: accountID,
            accountIdentity: accountIdentity,
            calendarID: event.calendar.calendarIdentifier,
            eventID: event.eventIdentifier,
            recurringEventID: event.hasRecurrenceRules ? event.calendarItemExternalIdentifier : nil,
            title: event.title ?? "(Untitled event)",
            startAtUnixMillis: Int64(event.startDate.timeIntervalSince1970 * 1_000),
            endAtUnixMillis: Int64(event.endDate.timeIntervalSince1970 * 1_000),
            timeZoneIdentifier: event.timeZone?.identifier ?? TimeZone.autoupdatingCurrent.identifier,
            recurrence: event.recurrenceRules?.map { String(describing: $0) } ?? [],
            revision: revision(for: event),
            canEdit: event.calendar.allowsContentModifications,
            isAllDay: event.isAllDay,
            canonicalIdentity: event.calendarItemExternalIdentifier.map {
                "\($0.lowercased())|\(Int64(event.startDate.timeIntervalSince1970 * 1_000))"
            }
        )
    }

    private func revision(for event: EKEvent) -> String {
        let recurrence = (event.recurrenceRules ?? []).map(String.init(describing:)).joined(separator: "|")
        let source = "\(event.eventIdentifier ?? "")|\(event.calendar.calendarIdentifier)|\(event.lastModifiedDate?.timeIntervalSince1970 ?? 0)|\(event.startDate.timeIntervalSince1970)|\(event.endDate.timeIntervalSince1970)|\(event.timeZone?.identifier ?? "")|\(event.isAllDay)|\(event.title ?? "")|\(recurrence)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func accessState(for status: EKAuthorizationStatus) -> AppleCalendarAccessState {
        let legacyMapping: [EKAuthorizationStatus: AppleCalendarAccessState] = [
            .notDetermined: .notRequested,
            .restricted: .restricted,
            .denied: .denied,
            .authorized: .ready,
        ]
        if let mapped = legacyMapping[status] { return mapped }
        if #available(macOS 14.0, iOS 17.0, *) {
            let modernMapping: [EKAuthorizationStatus: AppleCalendarAccessState] = [
                .writeOnly: .writeOnly,
                .fullAccess: .ready,
            ]
            return modernMapping[status] ?? .unavailable
        }
        return .unavailable
    }
}
#endif
