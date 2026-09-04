import KanameDesktop
import KanameDesktopUI
import KanameDesignSystem
import KanameWorkflowHost
import KanameConnectivity
import KanameDomain
import KanamePrototypeUI
import KanameLocalCore
import KanameLinkHost
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct DesktopCalendarView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @StateObject private var calendar = DesktopCalendarViewModel()
    @State private var showsProposal = false
    @State private var eventEditRequest: CalendarEventEditRequest?

    private var accounts: [DesktopAccountRecord] {
        model.snapshot.domains.accounts.filter {
            $0.service == .googleCalendar || $0.service == .appleCalendar
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Calendar",
                    detail: "Google and Apple calendars with pinned scheduling zones and local-time transparency",
                    symbol: DesktopDestination.calendar.symbol
                ) {
                    HStack(spacing: 8) {
                        Button("Refresh events", systemImage: "arrow.clockwise") {
                            calendar.refresh(
                                sources: model.snapshot.domains.calendarSources,
                                googleAccounts: integrations.googleAccounts
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(calendar.isBusy || model.snapshot.domains.calendarSources.filter(\.isEnabled).isEmpty)
                        Button("Propose event", systemImage: "calendar.badge.plus") { showsProposal = true }
                            .buttonStyle(.borderedProminent)
                    }
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        AccountStrip(accounts: accounts)
                        BoundaryCallout(
                            title: "Exact calendar authority",
                            detail: "Refresh is read-only. Create, change, and delete bind the exact account, calendar, event revision, recurrence scope, and resolved event fields before approval."
                        )
                        if !model.snapshot.domains.calendarSources.isEmpty {
                            SectionHeading(
                                title: "Visible calendars",
                                detail: "These private visibility choices never hide or delete calendars at the provider."
                            )
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                                ForEach(model.snapshot.domains.calendarSources) { source in
                                    CalendarSourceVisibilityCard(model: model, source: source)
                                }
                            }
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Label(
                        "Accounts & visible calendars",
                        systemImage: "calendar.badge.checkmark"
                    )
                    .font(.headline)
                }
                .panelStyle()

                SectionHeading(
                    title: "Upcoming events",
                    detail: "Read the next 90 days across enabled sources. Duplicate provider identities collapse before display."
                )
                if calendar.isBusy, calendar.events.isEmpty {
                    ProgressView("Reading enabled calendars…").frame(maxWidth: .infinity, minHeight: 180)
                } else if calendar.events.isEmpty {
                    EmptyPanel(symbol: "calendar", title: "Agenda not loaded", detail: "Refresh events when you want Kaname to read the enabled Google and Apple calendars.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                        ForEach(calendar.events) { event in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: event.provider == .apple ? "apple.logo" : "g.circle.fill")
                                        .foregroundStyle(KanameColor.accent)
                                    Text(event.title).font(.headline).lineLimit(2)
                                    Spacer()
                                    if event.recurringEventID != nil { Image(systemName: "repeat").foregroundStyle(.secondary) }
                                }
                                Text(Date(timeIntervalSince1970: Double(event.startAtUnixMillis) / 1_000).formatted(date: .abbreviated, time: .shortened))
                                    .font(.title3.weight(.semibold))
                                Text("\(event.accountIdentity) · \(event.timeZoneIdentifier)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if event.sourceProvenance.count > 1 {
                                    Label("Shown once from \(event.sourceProvenance.count) linked sources", systemImage: "link")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if event.provider == .google, !event.canEdit {
                                    Label("Reconnect this Google account in Settings to enable approved event changes.", systemImage: "person.crop.circle.badge.exclamationmark")
                                        .font(.caption).foregroundStyle(KanameColor.warning)
                                }
                                HStack {
                                    Button("Change") { eventEditRequest = CalendarEventEditRequest(event: event, kind: .update) }
                                    Button("Delete", role: .destructive) { eventEditRequest = CalendarEventEditRequest(event: event, kind: .delete) }
                                }
                                .disabled(!event.canEdit || source(for: event)?.accessLevel.lowercased().contains("reader") == true)
                            }
                            .panelStyle()
                        }
                    }
                }

                SectionHeading(
                    title: "Event proposals",
                    detail: "Proposals remain local until an exact calendar and consequence are approved."
                )
                if model.snapshot.domains.calendarProposals.isEmpty {
                    EmptyPanel(
                        symbol: "calendar.badge.clock",
                        title: "No calendar proposals",
                        detail: "Create a local event proposal with explicit time zone, duration, and recurrence."
                    )
                    .frame(minHeight: 240)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(model.snapshot.domains.calendarProposals.sorted { $0.startAtUnixMillis < $1.startAtUnixMillis }) { proposal in
                            let eventDate = Date(timeIntervalSince1970: Double(proposal.startAtUnixMillis) / 1_000)
                            let presentation = DesktopTimeZonePresenter.presentation(
                                for: eventDate,
                                anchoredTimeZoneIdentifier: proposal.timeZoneIdentifier
                            )
                            VStack(alignment: .leading, spacing: 11) {
                                HStack {
                                    Image(systemName: "calendar")
                                        .font(.title2)
                                        .foregroundStyle(KanameColor.blocked)
                                    Spacer()
                                    KanameStatusBadge(
                                        KanameDesktopStatusPresentation.record(proposal.status),
                                        density: .compact
                                    )
                                }
                                Text(proposal.title).font(.headline)
                                Text(presentation?.anchored ?? eventDate.formatted())
                                    .font(.title3.weight(.semibold))
                                if presentation?.differsFromViewer == true {
                                    Text("Here: \(presentation?.viewerLocal ?? "") (\(presentation?.viewerTimeZoneIdentifier ?? ""))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Divider()
                                if let sourceID = proposal.calendarSourceID,
                                   let source = model.snapshot.domains.calendarSources.first(where: { $0.id == sourceID }) {
                                    LabeledContent("Calendar", value: "\(source.displayName) · \(source.ownerIdentity)")
                                }
                                LabeledContent(
                                    proposal.isAllDay == true ? "All-day span" : "Duration",
                                    value: proposal.isAllDay == true
                                        ? "\(max(1, proposal.durationMinutes / 1_440)) day(s)"
                                        : "\(proposal.durationMinutes) minutes"
                                )
                                LabeledContent("Pinned zone", value: proposal.timeZoneIdentifier)
                                LabeledContent("Recurrence", value: proposal.recurrence)
                                if let scope = proposal.recurrenceScope.flatMap(CalendarRecurrenceScope.init(rawValue:)) {
                                    LabeledContent("Scope", value: scope.label)
                                }
                                if proposal.status == .running, let phase = proposal.mutationPhase {
                                    LabeledContent("Recovery phase", value: phase.replacingOccurrences(of: "Applied", with: " applied").capitalized)
                                }
                                if let receipt = proposal.remoteReceipt {
                                    Text(receipt).foregroundStyle(proposal.status == .failed ? KanameColor.danger : KanameColor.success)
                                }
                                calendarProposalAction(proposal)
                            }
                            .font(.caption)
                            .panelStyle()
                        }
                    }
                }
                if !calendar.failedSources.isEmpty {
                    BoundaryCallout(title: "Partial calendar refresh", detail: "Other sources remain usable. Retry: \(calendar.failedSources.joined(separator: ", ")).")
                }
                if let message = calendar.message { BoundaryCallout(title: "Calendar status", detail: message) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.canvas)
        .sheet(isPresented: $showsProposal) {
            NewCalendarProposalSheet(model: model)
        }
        .sheet(item: $eventEditRequest) { request in
            CalendarEventMutationSheet(
                request: request,
                source: source(for: request.event),
                model: model,
                calendar: calendar,
                googleAccounts: integrations.googleAccounts
            )
        }
    }

    @ViewBuilder
    private func calendarProposalAction(_ proposal: DesktopCalendarProposal) -> some View {
        let approval = proposal.approvalID.flatMap { id in model.snapshot.operations.approvals.first { $0.id == id } }
        if proposal.status == .proposed,
           let source = model.snapshot.domains.calendarSources.first(where: { $0.id == proposal.calendarSourceID }) {
            Button("Review create") {
                calendar.proposeCreate(model: model, proposal: proposal, source: source, googleAccounts: integrations.googleAccounts)
            }
            .buttonStyle(.borderedProminent)
        } else if proposal.status == .needsReview {
            Button("Request approval") {
                calendar.selectProposal(proposal.id)
                calendar.requestApproval(model: model)
            }
            .buttonStyle(.borderedProminent)
        } else if approval?.state == .approved {
            Button(proposal.status == .running ? "Reconcile action" : "Apply approved action") {
                executeCalendarProposal(proposal)
            }
            .buttonStyle(.borderedProminent)
            .disabled(calendar.isBusy)
        } else if proposal.status == .waiting {
            Label("Waiting in Inbox", systemImage: "tray.full").foregroundStyle(KanameColor.warning)
        } else if proposal.status == .failed,
                  let source = model.snapshot.domains.calendarSources.first(where: { $0.id == proposal.calendarSourceID }) {
            Button("Review again") {
                calendar.selectProposal(proposal.id)
                calendar.prepareAgain(model: model, proposal: proposal, source: source, googleAccounts: integrations.googleAccounts)
            }
            .buttonStyle(.bordered)
        }
    }

    private func executeCalendarProposal(_ proposal: DesktopCalendarProposal) {
        calendar.selectProposal(proposal.id)
        calendar.execute(
            model: model,
            sources: model.snapshot.domains.calendarSources,
            googleAccounts: integrations.googleAccounts
        )
    }

    private func source(for event: CalendarEventSnapshot) -> DesktopCalendarSourceRecord? {
        model.snapshot.domains.calendarSources.first {
            $0.externalIdentifier == event.calendarID
                && $0.provider.rawValue == event.provider.rawValue
                && $0.ownerIdentity == event.accountIdentity
        }
    }
}

private struct CalendarSourceVisibilityCard: View {
    @ObservedObject var model: DesktopAppModel
    let source: DesktopCalendarSourceRecord

    var body: some View {
        LabeledContent {
            Toggle(
                "Visible",
                isOn: Binding(
                    get: { source.isEnabled },
                    set: { model.setCalendarSourceEnabled(id: source.id, enabled: $0) }
                )
            )
            .labelsHidden()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.displayName).font(.subheadline.weight(.semibold))
                    Text("\(source.ownerIdentity) · \(source.accessLevel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: source.provider == .apple ? "apple.logo" : "g.circle.fill")
                    .foregroundStyle(source.isEnabled ? KanameColor.accent : .secondary)
            }
        }
        .padding(12)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CalendarEventEditRequest: Identifiable {
    let id = UUID()
    let event: CalendarEventSnapshot
    let kind: DesktopCalendarProposal.MutationKind
}

private struct CalendarEventMutationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: CalendarEventEditRequest
    let source: DesktopCalendarSourceRecord?
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var calendar: DesktopCalendarViewModel
    let googleAccounts: [NativeGoogleAccountSnapshot]
    @State private var title: String
    @State private var start: Date
    @State private var durationMinutes: Int
    @State private var scope: CalendarRecurrenceScope

    init(
        request: CalendarEventEditRequest,
        source: DesktopCalendarSourceRecord?,
        model: DesktopAppModel,
        calendar: DesktopCalendarViewModel,
        googleAccounts: [NativeGoogleAccountSnapshot]
    ) {
        self.request = request
        self.source = source
        self.model = model
        self.calendar = calendar
        self.googleAccounts = googleAccounts
        _title = State(initialValue: request.event.title)
        _start = State(initialValue: Date(timeIntervalSince1970: Double(request.event.startAtUnixMillis) / 1_000))
        _durationMinutes = State(initialValue: max(1, Int((request.event.endAtUnixMillis - request.event.startAtUnixMillis) / 60_000)))
        _scope = State(initialValue: request.event.recurringEventID == nil ? .thisEvent : .thisEvent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.kind == .delete ? "Review event deletion" : "Propose event change").font(.title2.weight(.bold))
            Text("Nothing changes yet. Kaname binds the current event revision and recurrence scope before approval.")
                .foregroundStyle(.secondary)
            Form {
                LabeledContent("Calendar", value: source.map { "\($0.displayName) · \($0.ownerIdentity)" } ?? "Source unavailable")
                if request.kind == .update {
                    TextField("Title", text: $title)
                    DatePicker(
                        request.event.isAllDay ? "Date" : "Start",
                        selection: $start,
                        displayedComponents: request.event.isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    if request.event.isAllDay {
                        Stepper("Span: \(max(1, durationMinutes / 1_440)) day(s)", value: $durationMinutes, in: 1_440...10_080, step: 1_440)
                    } else {
                        Stepper("Duration: \(durationMinutes) minutes", value: $durationMinutes, in: 5...10_080, step: 5)
                    }
                } else {
                    LabeledContent("Event", value: request.event.title)
                    LabeledContent("Starts", value: start.formatted())
                }
                if request.event.recurringEventID != nil {
                    Picker("Recurrence scope", selection: $scope) {
                        ForEach(CalendarRecurrenceScope.allCases.filter {
                            source?.provider != .apple || $0 != .entireSeries
                        }, id: \.self) { Text($0.label).tag($0) }
                    }
                } else {
                    LabeledContent("Recurrence scope", value: CalendarRecurrenceScope.thisEvent.label)
                }
                if scope == .thisAndFuture {
                    Label("Kaname validates the provider's recurrence before approval. Unsupported finite Google series are refused; Apple uses its native future-events span.", systemImage: "scissors")
                        .font(.caption).foregroundStyle(KanameColor.warning)
                }
                if source?.provider == .apple, request.event.recurringEventID != nil {
                    Text("EventKit does not expose a safe whole-series operation, so Apple Calendar offers only this event or this and future events.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(request.kind == .delete ? "Review deletion" : "Review change") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(source == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 600, idealHeight: 470)
    }

    private func save() {
        guard let source else { return }
        var pinnedCalendar = Calendar(identifier: .gregorian)
        pinnedCalendar.timeZone = TimeZone(identifier: request.event.timeZoneIdentifier) ?? .autoupdatingCurrent
        let normalizedStart = request.event.isAllDay ? pinnedCalendar.startOfDay(for: start) : start
        let startMillis = Int64(normalizedStart.timeIntervalSince1970 * 1_000)
        let factory = request.event.isAllDay ? CalendarEventDraft.allDay : CalendarEventDraft.timed
        let draft = factory(
            title,
            startMillis,
            startMillis + Int64(durationMinutes) * 60_000,
            request.event.timeZoneIdentifier,
            request.event.recurrence.first ?? (request.event.recurringEventID == nil ? "Does not repeat" : "Recurring")
        )
        calendar.proposeChange(
            model: model,
            event: request.event,
            source: source,
            kind: request.kind,
            scope: request.event.recurringEventID == nil ? .thisEvent : scope,
            draft: draft,
            googleAccounts: googleAccounts
        )
        dismiss()
    }
}
