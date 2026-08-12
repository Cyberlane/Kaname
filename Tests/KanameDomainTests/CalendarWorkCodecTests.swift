import Foundation
@testable import KanameConnectivity
import Testing

@MainActor
struct CalendarWorkCodecTests {
    @Test
    func googleEventPageParsesTimedAndAllDayEventsWhileDiscardingCancelledEntries() throws {
        let account = NativeGoogleAccountSnapshot(
            id: "google-account-1",
            identity: "calendar@example.test",
            displayName: "Calendar Fixture",
            capabilities: ["calendar"]
        )
        let fixture = Data(
            #"""
            {
              "items": [
                {
                  "id": "timed-event",
                  "etag": "revision-1",
                  "status": "confirmed",
                  "summary": "Focused review",
                  "start": {"dateTime": "2026-08-10T09:30:00+09:00", "timeZone": "Asia/Tokyo"},
                  "end": {"dateTime": "2026-08-10T10:15:00+09:00", "timeZone": "Asia/Tokyo"},
                  "recurrence": ["RRULE:FREQ=WEEKLY;COUNT=4"],
                  "recurringEventId": "series-1"
                },
                {
                  "id": "all-day-event",
                  "etag": "revision-2",
                  "status": "confirmed",
                  "start": {"date": "2026-08-12", "timeZone": "Asia/Tokyo"},
                  "end": {"date": "2026-08-13", "timeZone": "Asia/Tokyo"}
                },
                {
                  "id": "cancelled-event",
                  "etag": "revision-3",
                  "status": "cancelled",
                  "start": {"dateTime": "2026-08-14T09:00:00Z"},
                  "end": {"dateTime": "2026-08-14T10:00:00Z"}
                }
              ],
              "nextPageToken": "next-page",
              "nextSyncToken": "next-sync"
            }
            """#.utf8
        )

        let page = try CalendarWorkCodec.googleEventPage(
            data: fixture,
            account: account,
            calendarID: "primary"
        )

        #expect(page.nextPageToken == "next-page")
        #expect(page.nextSyncToken == "next-sync")
        #expect(page.events.count == 2)
        let timed = try #require(page.events.first { $0.eventID == "timed-event" })
        #expect(timed.accountID == account.id)
        #expect(timed.title == "Focused review")
        #expect(timed.timeZoneIdentifier == "Asia/Tokyo")
        #expect(timed.recurrence == ["RRULE:FREQ=WEEKLY;COUNT=4"])
        #expect(timed.recurringEventID == "series-1")
        #expect(timed.endAtUnixMillis - timed.startAtUnixMillis == 45 * 60 * 1_000)
        let allDay = try #require(page.events.first { $0.eventID == "all-day-event" })
        #expect(allDay.title == "(Untitled event)")
        #expect(allDay.isAllDay)
        let oneDayInMillis: Int64 = 86_400_000
        #expect(allDay.endAtUnixMillis - allDay.startAtUnixMillis == oneDayInMillis)
    }

    @Test
    func allDayDraftSerializesGoogleDateBoundariesWithoutTimedFields() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = tokyo
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 13)))
        let draft = CalendarEventDraft.allDay(
            title: "All-day review",
            startAtUnixMillis: Int64(start.timeIntervalSince1970 * 1_000),
            endAtUnixMillis: Int64(end.timeIntervalSince1970 * 1_000),
            timeZoneIdentifier: tokyo.identifier,
            recurrence: "weekly"
        )
        let data = try CalendarWorkCodec.googleEventBody(
            draft: draft,
            recurrence: ["RRULE:FREQ=WEEKLY"],
            eventID: "kaname-all-day-fixture"
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let startObject = try #require(object["start"] as? [String: Any])
        let endObject = try #require(object["end"] as? [String: Any])

        #expect(draft.isAllDay)
        #expect(object["id"] as? String == "kaname-all-day-fixture")
        #expect(startObject["date"] as? String == "2026-08-12")
        #expect(endObject["date"] as? String == "2026-08-13")
        #expect(startObject["dateTime"] == nil)
        #expect(endObject["dateTime"] == nil)
    }

    @Test
    func mutationTargetsBindProviderAccountCalendarPayloadRevisionAndScope() throws {
        let draft = CalendarEventDraft(
            title: "Review Kaname",
            startAtUnixMillis: 1_786_309_200_000,
            endAtUnixMillis: 1_786_310_100_000,
            timeZoneIdentifier: "Asia/Tokyo",
            recurrence: "weekly"
        )
        let event = eventFixture(revision: "revision-a")
        let update = CalendarMutation.update(existing: event, draft: draft, scope: .thisEvent)
        let googleTarget = try NativeGoogleIntegrationService.googleCalendarTarget(
            accountID: event.accountID,
            calendarID: "team/calendar@example.test",
            operationID: "operation-1",
            mutation: update
        )
        let repeatedTarget = try NativeGoogleIntegrationService.googleCalendarTarget(
            accountID: event.accountID,
            calendarID: "team/calendar@example.test",
            operationID: "operation-1",
            mutation: update
        )
        let wholeSeriesTarget = try NativeGoogleIntegrationService.googleCalendarTarget(
            accountID: event.accountID,
            calendarID: "team/calendar@example.test",
            operationID: "operation-1",
            mutation: .update(existing: event, draft: draft, scope: .entireSeries)
        )
        let newerRevisionTarget = try NativeGoogleIntegrationService.googleCalendarTarget(
            accountID: event.accountID,
            calendarID: "team/calendar@example.test",
            operationID: "operation-1",
            mutation: .update(existing: eventFixture(revision: "revision-b"), draft: draft, scope: .thisEvent)
        )
        let appleTarget = try AppleCalendarIntegrationService.mutationTarget(
            accountID: event.accountID,
            calendarID: "local-calendar",
            operationID: "operation-1",
            mutation: update
        )

        #expect(googleTarget == repeatedTarget)
        #expect(googleTarget.hasPrefix("google-calendar:account-1:team%2Fcalendar%40example%2Etest:update:operation-1:sha256="))
        #expect(googleTarget != wholeSeriesTarget)
        #expect(googleTarget != newerRevisionTarget)
        #expect(appleTarget.hasPrefix("apple-calendar:account-1:local-calendar:update:operation-1:sha256="))
        #expect(appleTarget != googleTarget)
    }

    @Test
    func createTargetIsStableForOneOperationAndDistinctAcrossIdenticalOperations() throws {
        let draft = CalendarEventDraft.timed(
            title: "Idempotent review",
            startAtUnixMillis: 1_786_309_200_000,
            endAtUnixMillis: 1_786_310_100_000,
            timeZoneIdentifier: "Asia/Tokyo",
            recurrence: "weekly"
        )
        let mutation = CalendarMutation.create(draft)
        let first = try NativeGoogleIntegrationService.googleCalendarTarget(
            accountID: "account-1",
            calendarID: "primary",
            operationID: "calendar-proposal-1",
            mutation: mutation
        )
        let retry = try NativeGoogleIntegrationService.googleCalendarTarget(
            accountID: "account-1",
            calendarID: "primary",
            operationID: "calendar-proposal-1",
            mutation: mutation
        )
        let separateOperation = try NativeGoogleIntegrationService.googleCalendarTarget(
            accountID: "account-1",
            calendarID: "primary",
            operationID: "calendar-proposal-2",
            mutation: mutation
        )
        let firstEventID = CalendarWorkCodec.deterministicGoogleEventID(exactTarget: first)
        let retryEventID = CalendarWorkCodec.deterministicGoogleEventID(exactTarget: retry)
        let separateEventID = CalendarWorkCodec.deterministicGoogleEventID(exactTarget: separateOperation)

        #expect(first == retry)
        #expect(first != separateOperation)
        #expect(firstEventID == retryEventID)
        #expect(firstEventID != separateEventID)
    }

    @Test
    func recurrenceSplitTruncatesOldSeriesAndRemovesBoundsFromTheNewSeries() throws {
        let occurrenceStart: Int64 = 1_786_309_200_000
        let original = [
            "DTSTART;TZID=Asia/Tokyo:20260810T093000",
            "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261231T000000Z",
            "RDATE;TZID=Asia/Tokyo:20260803T093000,20260817T093000",
            "EXDATE;TZID=Asia/Tokyo:20260803T093000,20260824T093000",
        ]

        let split = try CalendarWorkCodec.splitRecurrence(original, beforeUnixMillis: occurrenceStart)
        let oldSeries = split.prior
        let newSeries = split.future

        let oldRule = try #require(oldSeries.first { $0.hasPrefix("RRULE:") })
        #expect(oldRule.contains("FREQ=WEEKLY"))
        #expect(oldRule.contains("BYDAY=MO"))
        #expect(oldRule.contains("UNTIL="))
        #expect(!oldRule.contains("COUNT="))
        #expect(oldSeries.contains("RDATE;TZID=Asia/Tokyo:20260803T093000"))
        #expect(oldSeries.contains("EXDATE;TZID=Asia/Tokyo:20260803T093000"))
        #expect(!oldSeries.joined().contains("20260817T093000"))
        #expect(!oldSeries.joined().contains("20260824T093000"))
        let newRule = try #require(newSeries.first { $0.hasPrefix("RRULE:") })
        #expect(newRule == "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261231T000000Z")
        #expect(newSeries.contains("RDATE;TZID=Asia/Tokyo:20260817T093000"))
        #expect(newSeries.contains("EXDATE;TZID=Asia/Tokyo:20260824T093000"))
        #expect(!newSeries.joined().contains("20260803T093000"))
        #expect(throws: CalendarWorkError.recurrenceSplitUnavailable) {
            try CalendarWorkCodec.splitRecurrence(
                ["RRULE:FREQ=WEEKLY;COUNT=12"],
                beforeUnixMillis: occurrenceStart
            )
        }
        #expect(try CalendarWorkCodec.scopedEventID(eventFixture(), scope: .thisEvent) == "occurrence-1")
        #expect(try CalendarWorkCodec.scopedEventID(eventFixture(), scope: .entireSeries) == "series-1")
        #expect(throws: CalendarWorkError.recurrenceSplitUnavailable) {
            try CalendarWorkCodec.scopedEventID(eventFixture(), scope: .thisAndFuture)
        }
        #expect(throws: CalendarWorkError.recurrenceSplitUnavailable) {
            try CalendarWorkCodec.trimmedRecurrence(["EXDATE:20260824T003000Z"], beforeUnixMillis: occurrenceStart)
        }
        #expect(throws: CalendarWorkError.recurrenceSplitUnavailable) {
            try CalendarWorkCodec.splitRecurrence(
                ["RRULE:FREQ=WEEKLY", "RRULE:FREQ=DAILY"],
                beforeUnixMillis: occurrenceStart
            )
        }
        #expect(throws: CalendarWorkError.recurrenceSplitUnavailable) {
            try CalendarWorkCodec.splitRecurrence(
                ["RRULE:FREQ=WEEKLY", "EXRULE:FREQ=MONTHLY"],
                beforeUnixMillis: occurrenceStart
            )
        }
    }

    @Test
    func recurrenceSplitPlacesBoundaryDatesInTheFuturePartition() throws {
        let boundary = try #require(ISO8601DateFormatter().date(from: "2026-08-10T00:00:00Z"))
        let split = try CalendarWorkCodec.splitRecurrence(
            [
                "DTSTART:20260803T000000Z",
                "RRULE:FREQ=WEEKLY;UNTIL=20261231T000000Z",
                "RDATE:20260801T000000Z,20260810T000000Z,20260820T000000Z",
                "EXDATE:20260805T000000Z,20260810T000000Z,20260815T000000Z",
            ],
            beforeUnixMillis: Int64(boundary.timeIntervalSince1970 * 1_000)
        )

        #expect(split.prior == [
            "DTSTART:20260803T000000Z",
            "RRULE:FREQ=WEEKLY;UNTIL=20260809T235959Z",
            "RDATE:20260801T000000Z",
            "EXDATE:20260805T000000Z",
        ])
        #expect(split.future == [
            "DTSTART:20260810T000000Z",
            "RRULE:FREQ=WEEKLY;UNTIL=20261231T000000Z",
            "RDATE:20260810T000000Z,20260820T000000Z",
            "EXDATE:20260810T000000Z,20260815T000000Z",
        ])
    }

    @Test
    func recurrenceComparisonNormalizesOrderAndEntireSeriesTargetBindsMasterDelta() throws {
        let first = [
            "EXDATE;TZID=Asia/Tokyo:20260824T093000",
            "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261231T000000Z",
        ]
        let reordered = [
            "rrule:freq=weekly;byday=mo;until=20261231t000000z",
            "exdate;TZID=Asia/Tokyo:20260824T093000",
        ]
        #expect(CalendarWorkCodec.recurrenceEquals(first, reordered))
        #expect(!CalendarWorkCodec.recurrenceEquals(first, ["RRULE:FREQ=WEEKLY;BYDAY=TU"]))

        var original = eventFixture(revision: "occurrence-revision")
        original.seriesMasterRevision = "master-revision-1"
        original.seriesMasterRecurrence = first
        var changedMaster = original
        changedMaster.seriesMasterRevision = "master-revision-2"
        changedMaster.seriesMasterRecurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20270131T000000Z"]
        let draft = CalendarEventDraft.timed(
            title: original.title,
            startAtUnixMillis: original.startAtUnixMillis,
            endAtUnixMillis: original.endAtUnixMillis,
            timeZoneIdentifier: original.timeZoneIdentifier,
            recurrence: "weekly"
        )
        let originalTarget = try NativeGoogleIntegrationService.googleCalendarTarget(
            accountID: original.accountID,
            calendarID: original.calendarID,
            operationID: "entire-series-operation",
            mutation: .update(existing: original, draft: draft, scope: .entireSeries)
        )
        let changedTarget = try NativeGoogleIntegrationService.googleCalendarTarget(
            accountID: changedMaster.accountID,
            calendarID: changedMaster.calendarID,
            operationID: "entire-series-operation",
            mutation: .update(existing: changedMaster, draft: draft, scope: .entireSeries)
        )

        #expect(originalTarget != changedTarget)
    }

    @Test
    func entireSeriesDraftAppliesTheReviewedOccurrenceDeltaToTheSeriesMaster() {
        let selected = eventFixture(revision: "occurrence-revision")
        let week: Int64 = 7 * 86_400_000
        let master = CalendarEventSnapshot(
            provider: .google,
            accountID: selected.accountID,
            accountIdentity: selected.accountIdentity,
            calendarID: selected.calendarID,
            eventID: "series-1",
            recurringEventID: nil,
            title: selected.title,
            startAtUnixMillis: selected.startAtUnixMillis - week,
            endAtUnixMillis: selected.endAtUnixMillis - week,
            timeZoneIdentifier: selected.timeZoneIdentifier,
            recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO"],
            revision: "master-revision",
            canEdit: true
        )
        let twoHours: Int64 = 2 * 60 * 60 * 1_000
        let fortyFiveMinutes: Int64 = 45 * 60 * 1_000
        let approved = CalendarEventDraft.timed(
            title: "Renamed entire series",
            startAtUnixMillis: selected.startAtUnixMillis + twoHours,
            endAtUnixMillis: selected.startAtUnixMillis + twoHours + fortyFiveMinutes,
            timeZoneIdentifier: selected.timeZoneIdentifier,
            recurrence: "weekly"
        )

        let resolved = CalendarWorkCodec.seriesDraft(
            selectedEvent: selected,
            approvedDraft: approved,
            seriesMaster: master
        )

        #expect(resolved.title == approved.title)
        #expect(resolved.startAtUnixMillis == master.startAtUnixMillis + twoHours)
        #expect(resolved.endAtUnixMillis - resolved.startAtUnixMillis == fortyFiveMinutes)
        #expect(resolved.timeZoneIdentifier == approved.timeZoneIdentifier)
        #expect(resolved.recurrence == approved.recurrence)
    }

    @Test
    func deduplicationPrefersWritableSourceAndRetainsEverySourceProvenance() throws {
        var readOnly = eventFixture(revision: "read-only-revision")
        readOnly = CalendarEventSnapshot(
            provider: readOnly.provider,
            accountID: readOnly.accountID,
            accountIdentity: readOnly.accountIdentity,
            calendarID: "a-read-only",
            eventID: readOnly.eventID,
            recurringEventID: readOnly.recurringEventID,
            title: readOnly.title,
            startAtUnixMillis: readOnly.startAtUnixMillis,
            endAtUnixMillis: readOnly.endAtUnixMillis,
            timeZoneIdentifier: readOnly.timeZoneIdentifier,
            recurrence: readOnly.recurrence,
            revision: readOnly.revision,
            canEdit: false
        )
        readOnly.canonicalIdentity = "uid-1|\(readOnly.startAtUnixMillis)"
        readOnly.sourceProvenance = ["google:readonly@example.test:a-read-only"]
        var writable = CalendarEventSnapshot(
            provider: .google,
            accountID: "account-2",
            accountIdentity: "writer@example.test",
            calendarID: "z-writable",
            eventID: "writable-event",
            recurringEventID: nil,
            title: readOnly.title,
            startAtUnixMillis: readOnly.startAtUnixMillis,
            endAtUnixMillis: readOnly.endAtUnixMillis,
            timeZoneIdentifier: readOnly.timeZoneIdentifier,
            recurrence: readOnly.recurrence,
            revision: "writable-revision",
            canEdit: true
        )
        writable.canonicalIdentity = readOnly.canonicalIdentity
        writable.sourceProvenance = ["google:writer@example.test:z-writable"]

        let deduplicated = CalendarWorkCodec.deduplicated([readOnly, writable])
        let selected = try #require(deduplicated.first)
        #expect(deduplicated.count == 1)
        #expect(selected.canEdit)
        #expect(selected.accountID == writable.accountID)
        #expect(selected.sourceProvenance == [
            "google:readonly@example.test:a-read-only",
            "google:writer@example.test:z-writable",
        ])
    }

    private func eventFixture(revision: String = "revision-a") -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            provider: .google,
            accountID: "account-1",
            accountIdentity: "calendar@example.test",
            calendarID: "primary",
            eventID: "occurrence-1",
            recurringEventID: "series-1",
            title: "Review Kaname",
            startAtUnixMillis: 1_786_309_200_000,
            endAtUnixMillis: 1_786_310_100_000,
            timeZoneIdentifier: "Asia/Tokyo",
            recurrence: ["RRULE:FREQ=WEEKLY"],
            revision: revision,
            canEdit: true
        )
    }
}
