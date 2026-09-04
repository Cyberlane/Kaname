import Foundation
import KanameConnectivity
import KanameDesktop
import KanameLocalCore

/// Turns Google Calendar changes into workflow events.
///
/// Every five minutes, for each Google account and each of its calendars, the
/// poller advances an incremental-sync token and offers every changed event to
/// the Rust executor as a `calendar.event.changed` event. The executor fans it
/// out to every active workflow whose entrypoint is `trigger.event` with that
/// contract and deduplicates by event identity plus revision, so a real edit
/// fires again and a repeated page does not. Sync tokens persist under
/// Workflows/calendar-cursors.json; the first observation of a calendar only
/// records its token so existing events are not replayed. A 410 from Google
/// drops the token and re-baselines on the next poll.
final class DesktopCalendarEventPoller: @unchecked Sendable {
    static let shared = DesktopCalendarEventPoller()
    static let eventContract = "calendar.event.changed"

    private let queue = DispatchQueue(label: "com.cyberlane.kaname.calendar-event-poller", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var environment: KanameDesktopEnvironment = .current
    private var service: NativeGoogleIntegrationService?
    private var isPolling = false

    private init() {}

    func start(environment: KanameDesktopEnvironment) {
        queue.async { [self] in
            guard timer == nil else { return }
            self.environment = environment
            service = NativeGoogleIntegrationService(
                rootDirectory: environment.googleDirectory,
                keychainService: environment.googleKeychainService,
                clientConfiguration: nil,
                accessMode: environment.googleIntegrationAccessMode
            )
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 75, repeating: 300)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    private var cursorsURL: URL {
        DesktopWorkflowEventPolling.cursorsURL(environment, file: "calendar-cursors.json")
    }

    private func poll() {
        guard !isPolling, let service, let runner = LocalCoreRunner.bundled() else { return }
        isPolling = true
        Task.detached { [self] in
            defer { queue.async { self.isPolling = false } }
            guard await DesktopWorkflowEventPolling.hasActiveWorkflows(runner: runner, poller: "calendar-poller") else { return }
            guard let accounts = try? await service.accounts(), !accounts.isEmpty else { return }
            guard let calendars = try? await service.listCalendars(
                accountIDs: accounts.map(\.id), allowKeychainInteraction: false
            ) else { return }
            var cursors = DesktopWorkflowEventPolling.loadCursors(self.cursorsURL)
            for account in accounts {
                for calendar in calendars where calendar.accountIdentity == account.identity {
                    let calendarID = calendar.externalIdentifier
                    let key = "\(account.id)|\(calendarID)"
                    let token = cursors[key]
                    do {
                        let observation = try await service.observeCalendarEvents(
                            accountID: account.id, calendarID: calendarID, syncToken: token
                        )
                        if token != nil {
                            for event in observation.events {
                                _ = try? await runner.fanOutWorkflowEvent(
                                    contract: Self.eventContract,
                                    eventID: "gcal:\(account.id):\(calendarID):\(event.eventID):\(event.revision)",
                                    contractKey: event.recurringEventID ?? event.eventID,
                                    input: [
                                        "accountId": account.id,
                                        "accountIdentity": account.identity,
                                        "calendarId": calendarID,
                                        "calendarName": calendar.name,
                                        "eventId": event.eventID,
                                        "recurringEventId": event.recurringEventID ?? "",
                                        "title": event.title,
                                        "startAtUnixMillis": event.startAtUnixMillis,
                                        "endAtUnixMillis": event.endAtUnixMillis,
                                        "timeZone": event.timeZoneIdentifier,
                                        "isAllDay": event.isAllDay,
                                        "revision": event.revision,
                                        "provider": "google-calendar",
                                    ]
                                )
                            }
                        }
                        cursors[key] = observation.nextSyncToken
                    } catch GoogleCalendarObservationError.fullSyncRequired {
                        cursors[key] = nil
                    } catch {
                        continue
                    }
                }
            }
            DesktopWorkflowEventPolling.saveCursors(cursors, to: self.cursorsURL)
        }
    }
}
