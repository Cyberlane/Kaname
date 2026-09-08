import Foundation
import KanameConnectivity
import KanameDesktop
import KanameLocalCore

/// Turns Google Calendar changes into workflow events from the durable worker.
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
public final class DesktopCalendarEventPoller: @unchecked Sendable {
    public static let shared = DesktopCalendarEventPoller()
    public static let eventContract = "calendar.event.changed"

    private let queue = DispatchQueue(label: "com.cyberlane.kaname.calendar-event-poller", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var environment: KanameDesktopEnvironment = .current
    private var service: NativeGoogleIntegrationService?
    private var runner: LocalCoreRunner?
    private var isPolling = false

    private init() {}

    public func start(
        environment: KanameDesktopEnvironment,
        runner: LocalCoreRunner? = nil,
        googleClientConfiguration: GoogleOAuthClientConfiguration? = nil
    ) {
        queue.async { [self] in
            guard timer == nil else { return }
            self.environment = environment
            self.runner = runner
            service = NativeGoogleIntegrationService(
                rootDirectory: environment.googleDirectory,
                keychainService: environment.googleKeychainService,
                clientConfiguration: googleClientConfiguration,
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
        guard !isPolling, let service, let runner = self.runner ?? LocalCoreRunner.bundled() else { return }
        isPolling = true
        Task.detached { [self] in
            defer { queue.async { self.isPolling = false } }
            guard await DesktopWorkflowEventPolling.hasActiveWorkflows(runner: runner, poller: "calendar-poller") else { return }
            guard var cursors = DesktopWorkflowEventPolling.loadCursorsStrict(self.cursorsURL) else { return }
            guard let accounts = try? await service.accounts(), !accounts.isEmpty else { return }
            guard let calendars = try? await service.listCalendars(
                accountIDs: accounts.map(\.id), allowKeychainInteraction: false
            ) else { return }
            for account in accounts {
                for calendar in calendars where calendar.accountIdentity == account.identity {
                    let calendarID = calendar.externalIdentifier
                    let key = "\(account.id)|\(calendarID)"
                    let token = cursors[key]
                    var admission = DesktopWorkflowEventPolling.CursorAdmissionState(
                        cursor: token ?? "", maximumPages: 1, maximumEnrichments: Int.max
                    )
                    var calendarCompleted = true
                    do {
                        let observation = try await service.observeCalendarEvents(
                            accountID: account.id, calendarID: calendarID, syncToken: token
                        )
                        if token != nil {
                            for event in observation.events {
                                do {
                                    _ = try await runner.fanOutWorkflowEvent(
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
                                } catch {
                                    // A failed admission must be replayed from
                                    // the same sync token on the next cycle.
                                    calendarCompleted = false
                                    admission.fail()
                                    break
                                }
                            }
                        }
                        if calendarCompleted,
                           admission.acceptPage(latestCursor: observation.nextSyncToken, nextPageToken: nil),
                           let committed = admission.committedCursor {
                            cursors[key] = committed
                        }
                    } catch GoogleCalendarObservationError.fullSyncRequired {
                        // A provider-expired token is not an admission error;
                        // clearing it asks the next poll to establish a safe
                        // baseline without replaying the existing calendar.
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
