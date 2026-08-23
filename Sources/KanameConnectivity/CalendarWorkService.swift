import CryptoKit
import Foundation

public enum CalendarWorkProvider: String, Codable, Equatable, Sendable {
    case google
    case apple
}

public enum GoogleCalendarObservationError: Error, Equatable, LocalizedError, Sendable {
    case fullSyncRequired

    public var errorDescription: String? {
        "The Google Calendar change cursor expired. Review and establish a new baseline before resuming this trigger."
    }
}

public struct GoogleCalendarObservation: Equatable, Sendable {
    public let events: [CalendarEventSnapshot]
    public let nextSyncToken: String

    public init(events: [CalendarEventSnapshot], nextSyncToken: String) {
        self.events = events
        self.nextSyncToken = nextSyncToken
    }
}

public enum CalendarRecurrenceScope: String, Codable, CaseIterable, Equatable, Sendable {
    case thisEvent
    case thisAndFuture
    case entireSeries

    public var label: String {
        switch self {
        case .thisEvent: "This event only"
        case .thisAndFuture: "This and future events"
        case .entireSeries: "Entire series"
        }
    }
}

public struct CalendarEventSnapshot: Equatable, Identifiable, Sendable {
    public var stableID: String { "\(provider.rawValue):\(accountID):\(calendarID):\(id)" }
    public var id: String { eventID }
    public let provider: CalendarWorkProvider
    public let accountID: String
    public let accountIdentity: String
    public let calendarID: String
    public let eventID: String
    public let recurringEventID: String?
    public let title: String
    public let startAtUnixMillis: Int64
    public let endAtUnixMillis: Int64
    public let timeZoneIdentifier: String
    public let recurrence: [String]
    public let revision: String
    public let canEdit: Bool
    public var isAllDay: Bool = false
    public var canonicalIdentity: String? = nil
    public var sourceProvenance: [String] = []
    public var seriesMasterRevision: String? = nil
    public var seriesMasterRecurrence: [String]? = nil
    public var seriesMasterStartAtUnixMillis: Int64? = nil

    public static func restored(
        provider: CalendarWorkProvider,
        accountID: String,
        accountIdentity: String,
        calendarID: String,
        eventID: String,
        recurringEventID: String?,
        title: String,
        startAtUnixMillis: Int64,
        endAtUnixMillis: Int64,
        timeZoneIdentifier: String,
        recurrence: [String],
        revision: String,
        canEdit: Bool,
        isAllDay: Bool = false,
        canonicalIdentity: String? = nil,
        sourceProvenance: [String] = [],
        seriesMasterRevision: String? = nil,
        seriesMasterRecurrence: [String]? = nil,
        seriesMasterStartAtUnixMillis: Int64? = nil
    ) -> Self {
        Self(
            provider: provider,
            accountID: accountID,
            accountIdentity: accountIdentity,
            calendarID: calendarID,
            eventID: eventID,
            recurringEventID: recurringEventID,
            title: title,
            startAtUnixMillis: startAtUnixMillis,
            endAtUnixMillis: endAtUnixMillis,
            timeZoneIdentifier: timeZoneIdentifier,
            recurrence: recurrence,
            revision: revision,
            canEdit: canEdit,
            isAllDay: isAllDay,
            canonicalIdentity: canonicalIdentity,
            sourceProvenance: sourceProvenance,
            seriesMasterRevision: seriesMasterRevision,
            seriesMasterRecurrence: seriesMasterRecurrence,
            seriesMasterStartAtUnixMillis: seriesMasterStartAtUnixMillis
        )
    }
}

public struct CalendarEventDraft: Codable, Equatable, Sendable {
    public let title: String
    public let startAtUnixMillis: Int64
    public let endAtUnixMillis: Int64
    public let timeZoneIdentifier: String
    public let recurrence: String
    public var isAllDay: Bool = false

    public static func timed(
        title: String,
        startAtUnixMillis: Int64,
        endAtUnixMillis: Int64,
        timeZoneIdentifier: String,
        recurrence: String
    ) -> Self {
        Self(
            title: title,
            startAtUnixMillis: startAtUnixMillis,
            endAtUnixMillis: endAtUnixMillis,
            timeZoneIdentifier: timeZoneIdentifier,
            recurrence: recurrence
        )
    }

    public static func allDay(
        title: String,
        startAtUnixMillis: Int64,
        endAtUnixMillis: Int64,
        timeZoneIdentifier: String,
        recurrence: String
    ) -> Self {
        var value = Self.timed(
            title: title,
            startAtUnixMillis: startAtUnixMillis,
            endAtUnixMillis: endAtUnixMillis,
            timeZoneIdentifier: timeZoneIdentifier,
            recurrence: recurrence
        )
        value.isAllDay = true
        return value
    }
}

public enum CalendarMutationPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case prepared
    case dispatching
    case primaryApplied
    case secondaryApplied
    case reconciling
    case complete
}

public enum CalendarMutation: Equatable, Sendable {
    case create(CalendarEventDraft)
    case update(existing: CalendarEventSnapshot, draft: CalendarEventDraft, scope: CalendarRecurrenceScope)
    case delete(existing: CalendarEventSnapshot, scope: CalendarRecurrenceScope)

    var canonicalName: String {
        switch self {
        case .create: "create"
        case .update: "update"
        case .delete: "delete"
        }
    }
}

public struct CalendarMutationGrant: Equatable, Sendable {
    public let operationID: String
    public let approvalID: String
    public let exactTarget: String
    public let resumePhase: CalendarMutationPhase

    public static func approved(
        operationID: String,
        approvalID: String,
        exactTarget: String,
        resumePhase: CalendarMutationPhase = .prepared
    ) -> Self {
        Self(
            operationID: operationID,
            approvalID: approvalID,
            exactTarget: exactTarget,
            resumePhase: resumePhase
        )
    }
}

public struct CalendarMutationReceipt: Equatable, Sendable {
    public let approvalID: String
    public let exactTarget: String
    public let reconciledEvent: CalendarEventSnapshot?
    public let detail: String
}

public enum CalendarWorkError: Error, Equatable, LocalizedError {
    case accountNotFound
    case invalidEvent
    case approvalMismatch
    case revisionConflict
    case recurrenceSplitUnavailable
    case partialMutation
    case authorizationUpgradeRequired
    case calendarAccessUnavailable
    case reconciliationFailed

    public var errorDescription: String? {
        switch self {
        case .accountNotFound: "The selected calendar account is no longer connected."
        case .invalidEvent: "The calendar event contains invalid or incomplete values."
        case .approvalMismatch: "The calendar action changed after approval. Review it again."
        case .revisionConflict: "The event changed remotely. Kaname refused to overwrite the newer version."
        case .recurrenceSplitUnavailable: "This recurring series cannot be split safely because its master recurrence is unavailable."
        case .partialMutation: "The calendar series changed only partially. Kaname stopped and requires a fresh remote review before any retry."
        case .authorizationUpgradeRequired: "Reconnect this Google account to approve Calendar event changes."
        case .calendarAccessUnavailable: "Calendar access is unavailable. Review the permission in Settings and try again."
        case .reconciliationFailed: "The calendar accepted the request, but its remote result did not match the intended action."
        }
    }
}

public extension NativeGoogleIntegrationService {
    static func googleCalendarTarget(
        accountID: String,
        calendarID: String,
        operationID: String,
        mutation: CalendarMutation
    ) throws -> String {
        try ProviderActionTarget.sha256(
            scheme: "google-calendar",
            components: [accountID, CalendarWorkCodec.encodedPath(calendarID), mutation.canonicalName, operationID],
            payload: CalendarWorkCodec.canonicalPayload(mutation)
        )
    }

    func listCalendarEvents(
        accountID: String,
        calendarID: String,
        from start: Date,
        through end: Date,
        pageLimit: Int = 20
    ) async throws -> [CalendarEventSnapshot] {
        let account = try googleCalendarAccount(id: accountID)
        let token = try await validAccessToken(for: account)
        var events: [CalendarEventSnapshot] = []
        var pageToken: String?
        for _ in 0..<min(max(pageLimit, 1), 20) {
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(CalendarWorkCodec.encodedPath(calendarID))/events")!
            components.queryItems = [
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "timeMin", value: CalendarWorkCodec.rfc3339(start)),
                URLQueryItem(name: "timeMax", value: CalendarWorkCodec.rfc3339(end)),
                URLQueryItem(name: "maxResults", value: "250"),
            ]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data = try await authorizedData(url: components.url!, accessToken: token, service: "Google Calendar events")
            let page = try CalendarWorkCodec.googleEventPage(
                data: data,
                account: account,
                calendarID: calendarID
            )
            events.append(contentsOf: page.events)
            pageToken = page.nextPageToken
            if pageToken == nil { break }
        }
        return CalendarWorkCodec.deduplicated(events)
    }

    /// Establishes or advances a Google Calendar incremental-sync cursor. The
    /// initial response is suitable for a reviewed baseline; callers decide
    /// whether its existing events should be ingested.
    func observeCalendarEvents(
        accountID: String,
        calendarID: String,
        syncToken: String?,
        pageLimit: Int = 20
    ) async throws -> GoogleCalendarObservation {
        let account = try googleCalendarAccount(id: accountID)
        let token = try await validAccessToken(for: account)
        var events: [CalendarEventSnapshot] = []
        var pageToken: String?
        var nextSyncToken: String?
        for _ in 0..<min(max(pageLimit, 1), 20) {
            var components = URLComponents(
                string: "https://www.googleapis.com/calendar/v3/calendars/\(CalendarWorkCodec.encodedPath(calendarID))/events"
            )!
            components.queryItems = [
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "showDeleted", value: "true"),
                URLQueryItem(name: "maxResults", value: "250"),
            ]
            if let syncToken {
                components.queryItems?.append(URLQueryItem(name: "syncToken", value: syncToken))
            } else {
                components.queryItems?.append(URLQueryItem(
                    name: "timeMin", value: CalendarWorkCodec.rfc3339(Date().addingTimeInterval(-86_400))
                ))
            }
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data: Data
            do {
                data = try await authorizedData(
                    url: components.url!, accessToken: token, service: "Google Calendar changes"
                )
            } catch let error as NativeGoogleIntegrationError {
                if case let .httpStatus(_, status) = error, status == 410 {
                    throw GoogleCalendarObservationError.fullSyncRequired
                }
                throw error
            }
            let page = try CalendarWorkCodec.googleEventPage(
                data: data, account: account, calendarID: calendarID
            )
            events.append(contentsOf: page.events)
            pageToken = page.nextPageToken
            nextSyncToken = page.nextSyncToken ?? nextSyncToken
            if pageToken == nil { break }
        }
        guard pageToken == nil, let nextSyncToken, !nextSyncToken.isEmpty else {
            throw NativeGoogleIntegrationError.invalidResponse("Google Calendar changes")
        }
        return GoogleCalendarObservation(
            events: CalendarWorkCodec.deduplicated(events), nextSyncToken: nextSyncToken
        )
    }

    func googleCalendarEvent(
        accountID: String,
        calendarID: String,
        eventID: String
    ) async throws -> CalendarEventSnapshot {
        let account = try googleCalendarAccount(id: accountID)
        let token = try await validAccessToken(for: account)
        return try await readGoogleEvent(account: account, calendarID: calendarID, eventID: eventID, accessToken: token)
    }

    func mutateGoogleCalendar(
        accountID: String,
        calendarID: String,
        mutation: CalendarMutation,
        grant: CalendarMutationGrant,
        progress: @Sendable (CalendarMutationPhase) async -> Void = { _ in }
    ) async throws -> CalendarMutationReceipt {
        try requireExternalMutationAccess()
        let account = try googleCalendarAccount(id: accountID)
        guard account.supportsCalendarEventWrites else { throw CalendarWorkError.authorizationUpgradeRequired }
        let expectedTarget = try Self.googleCalendarTarget(
            accountID: account.id,
            calendarID: calendarID,
            operationID: grant.operationID,
            mutation: mutation
        )
        guard grant.exactTarget == expectedTarget else { throw CalendarWorkError.approvalMismatch }
        let token = try await validAccessToken(for: account)
        await progress(.dispatching)
        switch mutation {
        case let .create(draft):
            let eventID = CalendarWorkCodec.deterministicGoogleEventID(exactTarget: expectedTarget)
            let reconciled: CalendarEventSnapshot
            do {
                let data = try await writeGoogleEvent(
                    account: account,
                    calendarID: calendarID,
                    eventID: nil,
                    deterministicCreateID: eventID,
                    draft: draft,
                    recurrence: CalendarWorkCodec.recurrenceLines(draft.recurrence, startAtUnixMillis: draft.startAtUnixMillis),
                    revision: nil,
                    accessToken: token
                )
                let event = try CalendarWorkCodec.googleEvent(data: data, account: account, calendarID: calendarID)
                await progress(.primaryApplied)
                reconciled = try await readGoogleEvent(account: account, calendarID: calendarID, eventID: event.eventID, accessToken: token)
            } catch let error as NativeGoogleIntegrationError {
                guard case let .httpStatus(_, status) = error, status == 409 else { throw error }
                reconciled = try await readGoogleEvent(account: account, calendarID: calendarID, eventID: eventID, accessToken: token)
            }
            await progress(.reconciling)
            guard CalendarWorkCodec.matches(
                reconciled,
                draft: draft,
                expectedRecurrence: CalendarWorkCodec.recurrenceLines(draft.recurrence, startAtUnixMillis: draft.startAtUnixMillis)
            ) else { throw CalendarWorkError.reconciliationFailed }
            await progress(.complete)
            return CalendarMutationReceipt(approvalID: grant.approvalID, exactTarget: expectedTarget, reconciledEvent: reconciled, detail: "Created event and re-read revision \(reconciled.revision).")
        case let .update(existing, draft, scope):
            return try await updateGoogleEvent(
                account: account,
                calendarID: calendarID,
                existing: existing,
                draft: draft,
                scope: scope,
                grant: grant,
                target: expectedTarget,
                accessToken: token,
                progress: progress
            )
        case let .delete(existing, scope):
            return try await deleteGoogleEvent(
                account: account,
                calendarID: calendarID,
                existing: existing,
                scope: scope,
                grant: grant,
                target: expectedTarget,
                accessToken: token,
                progress: progress
            )
        }
    }

    private func updateGoogleEvent(
        account: NativeGoogleAccountSnapshot,
        calendarID: String,
        existing: CalendarEventSnapshot,
        draft: CalendarEventDraft,
        scope: CalendarRecurrenceScope,
        grant: CalendarMutationGrant,
        target: String,
        accessToken: String,
        progress: @Sendable (CalendarMutationPhase) async -> Void
    ) async throws -> CalendarMutationReceipt {
        if scope == .thisAndFuture, let masterID = existing.recurringEventID {
            guard let approvedMasterRevision = existing.seriesMasterRevision,
                  let approvedMasterRecurrence = existing.seriesMasterRecurrence else {
                throw CalendarWorkError.recurrenceSplitUnavailable
            }
            let splitEventID = CalendarWorkCodec.deterministicGoogleEventID(exactTarget: target)
            let split = try CalendarWorkCodec.splitRecurrence(
                approvedMasterRecurrence,
                beforeUnixMillis: existing.startAtUnixMillis
            )
            var child = try await readGoogleEventIfPresent(
                account: account,
                calendarID: calendarID,
                eventID: splitEventID,
                accessToken: accessToken
            )
            let recoveredExistingChild = child != nil
            if let child, !CalendarWorkCodec.matches(child, draft: draft, expectedRecurrence: split.future) {
                throw CalendarWorkError.reconciliationFailed
            }
            var master = try await readGoogleEvent(account: account, calendarID: calendarID, eventID: masterID, accessToken: accessToken)
            let masterIsOriginal = master.revision == approvedMasterRevision
                && CalendarWorkCodec.recurrenceEquals(master.recurrence, approvedMasterRecurrence)
            let masterIsTrimmed = CalendarWorkCodec.recurrenceEquals(master.recurrence, split.prior)
            guard masterIsOriginal || masterIsTrimmed else { throw CalendarWorkError.revisionConflict }

            if child == nil {
                do {
                    let data = try await writeGoogleEvent(
                        account: account,
                        calendarID: calendarID,
                        eventID: nil,
                        deterministicCreateID: splitEventID,
                        draft: draft,
                        recurrence: split.future,
                        revision: nil,
                        accessToken: accessToken
                    )
                    child = try CalendarWorkCodec.googleEvent(data: data, account: account, calendarID: calendarID)
                } catch let error as NativeGoogleIntegrationError {
                    guard case let .httpStatus(_, status) = error, status == 409 else { throw error }
                    child = try await readGoogleEvent(
                        account: account,
                        calendarID: calendarID,
                        eventID: splitEventID,
                        accessToken: accessToken
                    )
                }
                await progress(.primaryApplied)
            }

            if !masterIsTrimmed {
                do {
                    master = try await patchGoogleRecurrence(
                        calendarID: calendarID,
                        event: master,
                        recurrence: split.prior,
                        accessToken: accessToken
                    )
                } catch {
                    guard let child else { throw error }
                    do {
                        try await deleteGoogleEventResource(
                            calendarID: calendarID,
                            event: child,
                            accessToken: accessToken
                        )
                    } catch { throw CalendarWorkError.partialMutation }
                    throw error
                }
                await progress(.secondaryApplied)
            }

            await progress(.reconciling)
            let reconciledMaster = try await readGoogleEvent(
                account: account,
                calendarID: calendarID,
                eventID: masterID,
                accessToken: accessToken
            )
            let reconciled = try await readGoogleEvent(
                account: account,
                calendarID: calendarID,
                eventID: splitEventID,
                accessToken: accessToken
            )
            guard CalendarWorkCodec.recurrenceEquals(reconciledMaster.recurrence, split.prior),
                  CalendarWorkCodec.matches(reconciled, draft: draft, expectedRecurrence: split.future) else {
                throw CalendarWorkError.reconciliationFailed
            }
            await progress(.complete)
            return CalendarMutationReceipt(
                approvalID: grant.approvalID,
                exactTarget: target,
                reconciledEvent: reconciled,
                detail: recoveredExistingChild
                    ? "Recovered and reconciled both sides of the recurring-series split."
                    : "Split the recurring series, preserved prior events, and reconciled both remote postconditions."
            )
        }
        let eventID = try CalendarWorkCodec.scopedEventID(existing, scope: scope)
        let current = try await readGoogleEvent(account: account, calendarID: calendarID, eventID: eventID, accessToken: accessToken)
        let resolvedDraft = scope == .entireSeries
            ? CalendarWorkCodec.seriesDraft(
                selectedEvent: existing,
                approvedDraft: draft,
                seriesMasterStartAtUnixMillis: existing.seriesMasterStartAtUnixMillis ?? current.startAtUnixMillis
            )
            : draft
        let recurrence = scope == .entireSeries ? current.recurrence : []
        let approvedRevision = eventID == existing.eventID ? existing.revision : existing.seriesMasterRevision
        if current.revision != approvedRevision {
            guard CalendarWorkCodec.matches(
                current,
                draft: resolvedDraft,
                expectedRecurrence: scope == .entireSeries ? existing.seriesMasterRecurrence : recurrence
            ) else { throw CalendarWorkError.revisionConflict }
            await progress(.reconciling)
            await progress(.complete)
            return CalendarMutationReceipt(
                approvalID: grant.approvalID,
                exactTarget: target,
                reconciledEvent: current,
                detail: "Recovered the approved update and reconciled its remote revision without writing again."
            )
        }
        let data = try await writeGoogleEvent(
            account: account,
            calendarID: calendarID,
            eventID: eventID,
            draft: resolvedDraft,
            recurrence: recurrence,
            revision: current.revision,
            accessToken: accessToken
        )
        let changed = try CalendarWorkCodec.googleEvent(data: data, account: account, calendarID: calendarID)
        let reconciled = try await readGoogleEvent(account: account, calendarID: calendarID, eventID: changed.eventID, accessToken: accessToken)
        await progress(.primaryApplied)
        await progress(.reconciling)
        guard CalendarWorkCodec.matches(
            reconciled,
            draft: resolvedDraft,
            expectedRecurrence: recurrence
        ) else { throw CalendarWorkError.reconciliationFailed }
        await progress(.complete)
        return CalendarMutationReceipt(approvalID: grant.approvalID, exactTarget: target, reconciledEvent: reconciled, detail: "Updated the selected recurrence scope and re-read revision \(reconciled.revision).")
    }

    private func deleteGoogleEvent(
        account: NativeGoogleAccountSnapshot,
        calendarID: String,
        existing: CalendarEventSnapshot,
        scope: CalendarRecurrenceScope,
        grant: CalendarMutationGrant,
        target: String,
        accessToken: String,
        progress: @Sendable (CalendarMutationPhase) async -> Void
    ) async throws -> CalendarMutationReceipt {
        if scope == .thisAndFuture, let masterID = existing.recurringEventID {
            guard let approvedMasterRevision = existing.seriesMasterRevision,
                  let approvedMasterRecurrence = existing.seriesMasterRecurrence else {
                throw CalendarWorkError.recurrenceSplitUnavailable
            }
            let trimmed = try CalendarWorkCodec.trimmedRecurrence(
                approvedMasterRecurrence,
                beforeUnixMillis: existing.startAtUnixMillis
            )
            let master = try await readGoogleEvent(account: account, calendarID: calendarID, eventID: masterID, accessToken: accessToken)
            let masterIsOriginal = master.revision == approvedMasterRevision
                && CalendarWorkCodec.recurrenceEquals(master.recurrence, approvedMasterRecurrence)
            let masterIsTrimmed = CalendarWorkCodec.recurrenceEquals(master.recurrence, trimmed)
            guard masterIsOriginal || masterIsTrimmed else { throw CalendarWorkError.revisionConflict }
            if !masterIsTrimmed {
                _ = try await patchGoogleRecurrence(calendarID: calendarID, event: master, recurrence: trimmed, accessToken: accessToken)
                await progress(.primaryApplied)
            }
            await progress(.reconciling)
            let reconciledMaster = try await readGoogleEvent(
                account: account,
                calendarID: calendarID,
                eventID: masterID,
                accessToken: accessToken
            )
            guard CalendarWorkCodec.recurrenceEquals(reconciledMaster.recurrence, trimmed) else {
                throw CalendarWorkError.reconciliationFailed
            }
            await progress(.complete)
            return CalendarMutationReceipt(approvalID: grant.approvalID, exactTarget: target, reconciledEvent: reconciledMaster, detail: "Removed this and future occurrences by truncating and re-reading the series master.")
        }
        let eventID = try CalendarWorkCodec.scopedEventID(existing, scope: scope)
        guard let current = try await readGoogleEventIfPresent(
            account: account,
            calendarID: calendarID,
            eventID: eventID,
            accessToken: accessToken
        ) else {
            await progress(.reconciling)
            await progress(.complete)
            return CalendarMutationReceipt(
                approvalID: grant.approvalID,
                exactTarget: target,
                reconciledEvent: nil,
                detail: "Recovered the approved delete and confirmed the event no longer resolves."
            )
        }
        if eventID == existing.eventID {
            guard current.revision == existing.revision else { throw CalendarWorkError.revisionConflict }
        } else {
            guard current.revision == existing.seriesMasterRevision else { throw CalendarWorkError.revisionConflict }
        }
        var request = URLRequest(url: CalendarWorkCodec.googleEventURL(calendarID: calendarID, eventID: eventID))
        request.httpMethod = "DELETE"
        request.setValue(current.revision, forHTTPHeaderField: "If-Match")
        _ = try await authorizedData(request: request, accessToken: accessToken, service: "Google Calendar delete")
        await progress(.primaryApplied)
        await progress(.reconciling)
        do {
            _ = try await readGoogleEvent(account: account, calendarID: calendarID, eventID: eventID, accessToken: accessToken)
            throw CalendarWorkError.reconciliationFailed
        } catch let error as NativeGoogleIntegrationError {
            guard case let .httpStatus(_, status) = error, status == 404 || status == 410 else { throw error }
        }
        await progress(.complete)
        return CalendarMutationReceipt(approvalID: grant.approvalID, exactTarget: target, reconciledEvent: nil, detail: "Deleted the selected recurrence scope and confirmed the event no longer resolves.")
    }

    private func googleCalendarAccount(id: String) throws -> NativeGoogleAccountSnapshot {
        guard let account = try selectedAccounts([id]).first else { throw CalendarWorkError.accountNotFound }
        return account
    }

    private func readGoogleEvent(
        account: NativeGoogleAccountSnapshot,
        calendarID: String,
        eventID: String,
        accessToken: String
    ) async throws -> CalendarEventSnapshot {
        let data = try await authorizedData(
            url: CalendarWorkCodec.googleEventURL(calendarID: calendarID, eventID: eventID),
            accessToken: accessToken,
            service: "Google Calendar event reconciliation"
        )
        return try CalendarWorkCodec.googleEvent(data: data, account: account, calendarID: calendarID)
    }

    private func readGoogleEventIfPresent(
        account: NativeGoogleAccountSnapshot,
        calendarID: String,
        eventID: String,
        accessToken: String
    ) async throws -> CalendarEventSnapshot? {
        do {
            return try await readGoogleEvent(
                account: account,
                calendarID: calendarID,
                eventID: eventID,
                accessToken: accessToken
            )
        } catch let error as NativeGoogleIntegrationError {
            guard case let .httpStatus(_, status) = error, status == 404 || status == 410 else { throw error }
            return nil
        }
    }

    private func deleteGoogleEventResource(
        calendarID: String,
        event: CalendarEventSnapshot,
        accessToken: String
    ) async throws {
        var request = URLRequest(url: CalendarWorkCodec.googleEventURL(calendarID: calendarID, eventID: event.eventID))
        request.httpMethod = "DELETE"
        request.setValue(event.revision, forHTTPHeaderField: "If-Match")
        _ = try await authorizedData(request: request, accessToken: accessToken, service: "Google Calendar split compensation")
    }

    private func writeGoogleEvent(
        account: NativeGoogleAccountSnapshot,
        calendarID: String,
        eventID: String?,
        deterministicCreateID: String? = nil,
        draft: CalendarEventDraft,
        recurrence: [String],
        revision: String?,
        accessToken: String
    ) async throws -> Data {
        var request = URLRequest(url: eventID.map { CalendarWorkCodec.googleEventURL(calendarID: calendarID, eventID: $0) }
            ?? URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(CalendarWorkCodec.encodedPath(calendarID))/events")!)
        request.httpMethod = eventID == nil ? "POST" : "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let revision { request.setValue(revision, forHTTPHeaderField: "If-Match") }
        request.httpBody = try CalendarWorkCodec.googleEventBody(draft: draft, recurrence: recurrence, eventID: deterministicCreateID)
        return try await authorizedData(request: request, accessToken: accessToken, service: eventID == nil ? "Google Calendar create" : "Google Calendar update")
    }

    private func patchGoogleRecurrence(
        calendarID: String,
        event: CalendarEventSnapshot,
        recurrence: [String],
        accessToken: String
    ) async throws -> CalendarEventSnapshot {
        var request = URLRequest(url: CalendarWorkCodec.googleEventURL(calendarID: calendarID, eventID: event.eventID))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(event.revision, forHTTPHeaderField: "If-Match")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["recurrence": recurrence])
        let data = try await authorizedData(request: request, accessToken: accessToken, service: "Google Calendar recurrence split")
        return try CalendarWorkCodec.googleEvent(data: data, account: NativeGoogleAccountSnapshot(id: event.accountID, identity: event.accountIdentity, displayName: event.accountIdentity, capabilities: []), calendarID: calendarID)
    }
}

public enum CalendarWorkCodec {
    public struct GoogleEventPage: Equatable, Sendable {
        public let events: [CalendarEventSnapshot]
        public let nextPageToken: String?
        public let nextSyncToken: String?
    }

    public static func canonicalPayload(_ mutation: CalendarMutation) throws -> Data {
        struct Payload: Encodable {
            let action: String
            let eventID: String?
            let recurringEventID: String?
            let revision: String?
            let eventTitle: String?
            let eventStartAtUnixMillis: Int64?
            let eventEndAtUnixMillis: Int64?
            let eventTimeZoneIdentifier: String?
            let eventRecurrence: [String]?
            let eventIsAllDay: Bool?
            let seriesMasterRevision: String?
            let seriesMasterRecurrence: [String]?
            let seriesMasterStartAtUnixMillis: Int64?
            let scope: String?
            let draft: CalendarEventDraft?
        }
        let value: Payload = switch mutation {
        case let .create(draft): Payload(action: "create", eventID: nil, recurringEventID: nil, revision: nil, eventTitle: nil, eventStartAtUnixMillis: nil, eventEndAtUnixMillis: nil, eventTimeZoneIdentifier: nil, eventRecurrence: nil, eventIsAllDay: nil, seriesMasterRevision: nil, seriesMasterRecurrence: nil, seriesMasterStartAtUnixMillis: nil, scope: nil, draft: draft)
        case let .update(event, draft, scope): Payload(action: "update", eventID: event.eventID, recurringEventID: event.recurringEventID, revision: event.revision, eventTitle: event.title, eventStartAtUnixMillis: event.startAtUnixMillis, eventEndAtUnixMillis: event.endAtUnixMillis, eventTimeZoneIdentifier: event.timeZoneIdentifier, eventRecurrence: event.recurrence, eventIsAllDay: event.isAllDay, seriesMasterRevision: event.seriesMasterRevision, seriesMasterRecurrence: event.seriesMasterRecurrence, seriesMasterStartAtUnixMillis: event.seriesMasterStartAtUnixMillis, scope: scope.rawValue, draft: draft)
        case let .delete(event, scope): Payload(action: "delete", eventID: event.eventID, recurringEventID: event.recurringEventID, revision: event.revision, eventTitle: event.title, eventStartAtUnixMillis: event.startAtUnixMillis, eventEndAtUnixMillis: event.endAtUnixMillis, eventTimeZoneIdentifier: event.timeZoneIdentifier, eventRecurrence: event.recurrence, eventIsAllDay: event.isAllDay, seriesMasterRevision: event.seriesMasterRevision, seriesMasterRecurrence: event.seriesMasterRecurrence, seriesMasterStartAtUnixMillis: event.seriesMasterStartAtUnixMillis, scope: scope.rawValue, draft: nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func googleEventPage(
        data: Data,
        account: NativeGoogleAccountSnapshot,
        calendarID: String
    ) throws -> GoogleEventPage {
        struct Page: Decodable {
            let items: [GoogleWireEvent]?
            let nextPageToken: String?
            let nextSyncToken: String?
        }
        let page = try GoogleAPIResponseParser.decode(Page.self, from: data, service: "Google Calendar events")
        return GoogleEventPage(
            events: try (page.items ?? []).filter { $0.status != "cancelled" }.map {
                try snapshot($0, account: account, calendarID: calendarID)
            },
            nextPageToken: page.nextPageToken,
            nextSyncToken: page.nextSyncToken
        )
    }

    public static func googleEvent(data: Data, account: NativeGoogleAccountSnapshot, calendarID: String) throws -> CalendarEventSnapshot {
        do { return try snapshot(JSONDecoder().decode(GoogleWireEvent.self, from: data), account: account, calendarID: calendarID) }
        catch let error as CalendarWorkError { throw error }
        catch { throw NativeGoogleIntegrationError.invalidResponse("Google Calendar event") }
    }

    public static func googleEventBody(draft: CalendarEventDraft, recurrence: [String], eventID: String? = nil) throws -> Data {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.endAtUnixMillis > draft.startAtUnixMillis,
              TimeZone(identifier: draft.timeZoneIdentifier) != nil else { throw CalendarWorkError.invalidEvent }
        let start: [String: String]
        let end: [String: String]
        if draft.isAllDay {
            start = ["date": googleDate(draft.startAtUnixMillis, timeZoneIdentifier: draft.timeZoneIdentifier)]
            end = ["date": googleDate(draft.endAtUnixMillis, timeZoneIdentifier: draft.timeZoneIdentifier)]
        } else {
            start = ["dateTime": rfc3339(Date(timeIntervalSince1970: Double(draft.startAtUnixMillis) / 1_000)), "timeZone": draft.timeZoneIdentifier]
            end = ["dateTime": rfc3339(Date(timeIntervalSince1970: Double(draft.endAtUnixMillis) / 1_000)), "timeZone": draft.timeZoneIdentifier]
        }
        var object: [String: Any] = [
            "summary": draft.title,
            "start": start,
            "end": end,
            "recurrence": recurrence,
        ]
        if let eventID { object["id"] = eventID }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public static func recurrenceLines(_ value: String, startAtUnixMillis: Int64) -> [String] {
        switch value.lowercased() {
        case "daily": ["RRULE:FREQ=DAILY"]
        case "weekly": ["RRULE:FREQ=WEEKLY"]
        case "monthly": ["RRULE:FREQ=MONTHLY"]
        default: value.uppercased().hasPrefix("RRULE:") ? [value.uppercased()] : []
        }
    }

    public static func trimmedRecurrence(_ recurrence: [String], beforeUnixMillis: Int64) throws -> [String] {
        try partitionedRecurrence(recurrence, beforeUnixMillis: beforeUnixMillis).prior
    }

    public static func shiftedRecurrence(_ recurrence: [String], startAtUnixMillis: Int64) -> [String] {
        recurrence
    }

    public static func splitRecurrence(_ recurrence: [String], beforeUnixMillis: Int64) throws -> (prior: [String], future: [String]) {
        guard !recurrence.contains(where: { line in
            line.split(separator: ";").contains { $0.uppercased().hasPrefix("COUNT=") }
        }) else { throw CalendarWorkError.recurrenceSplitUnavailable }
        return try partitionedRecurrence(recurrence, beforeUnixMillis: beforeUnixMillis)
    }

    public static func scopedEventID(_ event: CalendarEventSnapshot, scope: CalendarRecurrenceScope) throws -> String {
        switch scope {
        case .thisEvent: return event.eventID
        case .entireSeries: return event.recurringEventID ?? event.eventID
        case .thisAndFuture:
            guard event.recurringEventID != nil else { return event.eventID }
            throw CalendarWorkError.recurrenceSplitUnavailable
        }
    }

    public static func matches(
        _ event: CalendarEventSnapshot,
        draft: CalendarEventDraft,
        expectedRecurrence: [String]? = nil
    ) -> Bool {
        guard event.title == draft.title,
              event.isAllDay == draft.isAllDay,
              expectedRecurrence.map({ recurrenceEquals(event.recurrence, $0) }) != false else { return false }
        if event.isAllDay {
            return googleDate(event.startAtUnixMillis, timeZoneIdentifier: event.timeZoneIdentifier)
                == googleDate(draft.startAtUnixMillis, timeZoneIdentifier: draft.timeZoneIdentifier)
                && googleDate(event.endAtUnixMillis, timeZoneIdentifier: event.timeZoneIdentifier)
                == googleDate(draft.endAtUnixMillis, timeZoneIdentifier: draft.timeZoneIdentifier)
        }
        return abs(event.startAtUnixMillis - draft.startAtUnixMillis) < 1_000
            && abs(event.endAtUnixMillis - draft.endAtUnixMillis) < 1_000
            && event.timeZoneIdentifier == draft.timeZoneIdentifier
    }

    public static func recurrenceEquals(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.map(normalizedRecurrenceLine).sorted() == rhs.map(normalizedRecurrenceLine).sorted()
    }

    public static func seriesDraft(
        selectedEvent: CalendarEventSnapshot,
        approvedDraft: CalendarEventDraft,
        seriesMaster: CalendarEventSnapshot
    ) -> CalendarEventDraft {
        seriesDraft(
            selectedEvent: selectedEvent,
            approvedDraft: approvedDraft,
            seriesMasterStartAtUnixMillis: seriesMaster.startAtUnixMillis
        )
    }

    public static func seriesDraft(
        selectedEvent: CalendarEventSnapshot,
        approvedDraft: CalendarEventDraft,
        seriesMasterStartAtUnixMillis: Int64
    ) -> CalendarEventDraft {
        let startDelta = approvedDraft.startAtUnixMillis - selectedEvent.startAtUnixMillis
        let duration = approvedDraft.endAtUnixMillis - approvedDraft.startAtUnixMillis
        return CalendarEventDraft(
            title: approvedDraft.title,
            startAtUnixMillis: seriesMasterStartAtUnixMillis + startDelta,
            endAtUnixMillis: seriesMasterStartAtUnixMillis + startDelta + duration,
            timeZoneIdentifier: approvedDraft.timeZoneIdentifier,
            recurrence: approvedDraft.recurrence,
            isAllDay: approvedDraft.isAllDay
        )
    }

    public static func deduplicated(_ events: [CalendarEventSnapshot]) -> [CalendarEventSnapshot] {
        Dictionary(grouping: events) { event in
            event.canonicalIdentity.map { "canonical:\($0)" } ?? "source:\(event.stableID)"
        }.compactMap { _, candidates in
            guard var selected = candidates.sorted(by: { lhs, rhs in
                if lhs.canEdit != rhs.canEdit { return lhs.canEdit }
                if lhs.provider != rhs.provider { return lhs.provider == .google }
                return lhs.stableID < rhs.stableID
            }).first else { return nil }
            selected.sourceProvenance = Array(Set(candidates.flatMap { event in
                event.sourceProvenance.isEmpty
                    ? ["\(event.provider.rawValue):\(event.accountIdentity):\(event.calendarID)"]
                    : event.sourceProvenance
            })).sorted()
            return selected
        }
            .sorted { $0.startAtUnixMillis < $1.startAtUnixMillis }
    }

    public static func deterministicGoogleEventID(exactTarget: String) -> String {
        let digest = SHA256.hash(data: Data(exactTarget.utf8)).map { String(format: "%02x", $0) }.joined()
        return "kaname\(digest)"
    }

    public static func encodedPath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    public static func googleEventURL(calendarID: String, eventID: String) -> URL {
        URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedPath(calendarID))/events/\(encodedPath(eventID))")!
    }

    public static func rfc3339(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func googleDate(_ unixMillis: Int64, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(unixMillis) / 1_000))
    }

    private static func normalizedRecurrenceLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func partitionedRecurrence(
        _ recurrence: [String],
        beforeUnixMillis: Int64
    ) throws -> (prior: [String], future: [String]) {
        let rules = recurrence.filter { $0.uppercased().hasPrefix("RRULE:") }
        guard rules.count == 1,
              !recurrence.contains(where: { $0.uppercased().hasPrefix("EXRULE:") }) else {
            throw CalendarWorkError.recurrenceSplitUnavailable
        }
        let boundary = Date(timeIntervalSince1970: Double(beforeUnixMillis) / 1_000)
        let until = compactUTC(boundary.addingTimeInterval(-1))
        var prior: [String] = []
        var future: [String] = []
        for line in recurrence {
            let upper = line.uppercased()
            if upper.hasPrefix("RRULE:") {
                let pieces = line.split(separator: ";").filter {
                    !$0.uppercased().hasPrefix("UNTIL=") && !$0.uppercased().hasPrefix("COUNT=")
                }
                prior.append((pieces + [Substring("UNTIL=\(until)")]).joined(separator: ";"))
                future.append(line)
            } else if upper.hasPrefix("RDATE") || upper.hasPrefix("EXDATE") {
                let partition = try partitionedDateLine(line, before: boundary)
                if let line = partition.prior { prior.append(line) }
                if let line = partition.future { future.append(line) }
            } else if upper.hasPrefix("DTSTART") {
                guard let separator = line.firstIndex(of: ":") else { throw CalendarWorkError.recurrenceSplitUnavailable }
                let prefix = String(line[...separator])
                let originalValue = String(line[line.index(after: separator)...])
                guard recurrenceDate(originalValue, prefix: prefix) != nil,
                      let shifted = recurrenceValue(boundary, matching: originalValue, prefix: prefix) else {
                    throw CalendarWorkError.recurrenceSplitUnavailable
                }
                prior.append(line)
                future.append(prefix + shifted)
            } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CalendarWorkError.recurrenceSplitUnavailable
            }
        }
        return (prior, future)
    }

    private static func partitionedDateLine(
        _ line: String,
        before boundary: Date
    ) throws -> (prior: String?, future: String?) {
        guard let separator = line.firstIndex(of: ":") else { throw CalendarWorkError.recurrenceSplitUnavailable }
        let prefix = String(line[...separator])
        let values = line[line.index(after: separator)...].split(separator: ",").map(String.init)
        guard !values.isEmpty else { throw CalendarWorkError.recurrenceSplitUnavailable }
        var priorValues: [String] = []
        var futureValues: [String] = []
        for value in values {
            guard let date = recurrenceDate(value, prefix: prefix) else { throw CalendarWorkError.recurrenceSplitUnavailable }
            if date < boundary {
                priorValues.append(value)
            } else {
                futureValues.append(value)
            }
        }
        return (
            priorValues.isEmpty ? nil : prefix + priorValues.joined(separator: ","),
            futureValues.isEmpty ? nil : prefix + futureValues.joined(separator: ",")
        )
    }

    private static func recurrenceDate(_ value: String, prefix: String) -> Date? {
        recurrenceFormatter(matching: value, prefix: prefix).date(from: value)
    }

    private static func recurrenceValue(_ date: Date, matching value: String, prefix: String) -> String? {
        guard recurrenceDate(value, prefix: prefix) != nil else { return nil }
        return recurrenceFormatter(matching: value, prefix: prefix).string(from: date)
    }

    private static func recurrenceFormatter(matching value: String, prefix: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if value.uppercased().hasSuffix("Z") {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else if value.count == 8 {
            formatter.timeZone = recurrenceTimeZone(prefix) ?? .autoupdatingCurrent
            formatter.dateFormat = "yyyyMMdd"
        } else {
            formatter.timeZone = recurrenceTimeZone(prefix) ?? .autoupdatingCurrent
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        }
        return formatter
    }

    private static func recurrenceTimeZone(_ prefix: String) -> TimeZone? {
        prefix.split(separator: ";").dropFirst().compactMap { component -> TimeZone? in
            let pieces = component.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2, pieces[0].uppercased() == "TZID" else { return nil }
            return TimeZone(identifier: String(pieces[1]).trimmingCharacters(in: CharacterSet(charactersIn: ":")))
        }.first
    }

    private static func compactUTC(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func snapshot(
        _ wire: GoogleWireEvent,
        account: NativeGoogleAccountSnapshot,
        calendarID: String
    ) throws -> CalendarEventSnapshot {
        guard let start = wire.start?.resolvedDate, let end = wire.end?.resolvedDate, end > start else {
            throw CalendarWorkError.invalidEvent
        }
        return CalendarEventSnapshot(
            provider: .google,
            accountID: account.id,
            accountIdentity: account.identity,
            calendarID: calendarID,
            eventID: wire.id,
            recurringEventID: wire.recurringEventId,
            title: wire.summary ?? "(Untitled event)",
            startAtUnixMillis: Int64(start.timeIntervalSince1970 * 1_000),
            endAtUnixMillis: Int64(end.timeIntervalSince1970 * 1_000),
            timeZoneIdentifier: wire.start?.timeZone ?? TimeZone.current.identifier,
            recurrence: wire.recurrence ?? [],
            revision: wire.etag,
            canEdit: account.supportsCalendarEventWrites,
            isAllDay: wire.start?.dateTime == nil,
            canonicalIdentity: wire.iCalUID.map { "\($0.lowercased())|\(Int64(start.timeIntervalSince1970 * 1_000))" }
        )
    }
}

public enum ProviderActionTarget {
    public static func sha256(scheme: String, components: [String], payload: Data) throws -> String {
        guard !scheme.isEmpty, components.allSatisfy({ !$0.isEmpty }) else { throw CalendarWorkError.invalidEvent }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return ([scheme] + components).joined(separator: ":") + ":sha256=\(digest)"
    }
}

private struct GoogleWireEvent: Decodable {
    struct Endpoint: Decodable {
        let dateTime: String?
        let date: String?
        let timeZone: String?

        var resolvedDate: Date? {
            if let dateTime { return ISO8601DateFormatter().date(from: dateTime) }
            guard let date else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: timeZone ?? TimeZone.current.identifier)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: date)
        }
    }
    let id: String
    let etag: String
    let status: String?
    let summary: String?
    let start: Endpoint?
    let end: Endpoint?
    let recurrence: [String]?
    let recurringEventId: String?
    let iCalUID: String?
}
