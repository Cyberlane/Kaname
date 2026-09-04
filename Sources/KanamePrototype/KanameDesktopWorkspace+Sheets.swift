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

struct NewMailRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var mail: DesktopMailViewModel
    let accounts: [NativeGoogleAccountSnapshot]
    @State private var accountID: String?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Gmail standing rule").font(.title2.weight(.bold))
            Text("This saves the current tested query as reversible archive authority for one account. It never covers Trash or Send.")
                .foregroundStyle(.secondary)
            Picker("Account", selection: $accountID) {
                Text("Choose account").tag(String?.none)
                ForEach(accounts) { Text($0.identity).tag(Optional($0.id)) }
            }
            TextField("Rule name", text: $name).textFieldStyle(.roundedBorder)
            LabeledContent("Gmail query", value: mail.query)
            LabeledContent("Action", value: "Archive")
            DesktopSheetActionBar(
                primaryTitle: "Save rule",
                isPrimaryEnabled: accountID != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                dismiss: dismiss.callAsFunction
            ) {
                    guard let account = accounts.first(where: { $0.id == accountID }) else { return }
                    mail.createStandingRule(model: model, account: account, name: name, action: .archive)
                    dismiss()
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 560)
        .onAppear { accountID = accountID ?? accounts.first?.id }
    }
}

struct NewResearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    let created: (String) -> Void
    @State private var title = ""
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New research")
                .font(.title2.weight(.bold))
            Text("Create a local research record and durable thread. No provider or search service starts from this form.")
                .foregroundStyle(.secondary)
            TextField("Short title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Question, decision, or desired output", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...10)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create research") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 540)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard model.createResearch(title: title, question: question) != nil,
              let threadID = model.createThread(title: title, kind: .research, projectID: nil) else { return }
        model.appendUserMessage(threadID: threadID, body: question)
        dismiss()
        created(threadID)
    }
}

struct NewResearchSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    let research: DesktopResearchRecord
    @State private var title = ""
    @State private var location = ""
    @State private var publisher = ""
    @State private var note = ""
    @State private var isPrimary = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add research source")
                .font(.title2.weight(.bold))
            Text(research.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Form {
                TextField("Source title", text: $title)
                TextField("URL or local reference", text: $location)
                TextField("Publisher or owner", text: $publisher)
                Toggle("Primary source", isOn: $isPrimary)
                TextField("Evidence note", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add source") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 560, idealHeight: 430)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard model.addResearchSource(
            researchID: research.id,
            title: title,
            location: location,
            publisher: publisher,
            isPrimary: isPrimary,
            note: note
        ) != nil else { return }
        dismiss()
    }
}

private struct NewKnowledgeProposalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @State private var sourceID: String?
    @State private var title = ""
    @State private var target = ""
    @State private var summary = ""
    @State private var proposedContent = ""
    @State private var baseRevision = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Propose knowledge edit")
                .font(.title2.weight(.bold))
            Text("This stores a reviewable local proposal. It does not write to Obsidian, Lode, or a repository.")
                .foregroundStyle(.secondary)
            Form {
                Picker("Knowledge source", selection: $sourceID) {
                    Text("Unlinked proposal").tag(nil as String?)
                    ForEach(model.snapshot.domains.knowledgeSources) { source in
                        Text(source.name).tag(source.id as String?)
                    }
                }
                TextField("Title", text: $title)
                TextField("Exact target path", text: $target)
                TextField("Summary", text: $summary)
                TextField("Base revision or digest", text: $baseRevision)
                TextEditor(text: $proposedContent)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150)
                    .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 9))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save proposal") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 640, idealHeight: 600)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !proposedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard model.createKnowledgeProposal(
            sourceID: sourceID,
            title: title,
            target: target,
            summary: summary,
            proposedContent: proposedContent,
            baseRevision: baseRevision
        ) != nil else { return }
        dismiss()
    }
}

struct NewGitStackLayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @State private var workspaceID: String?
    @State private var title = ""
    @State private var branch = ""
    @State private var baseBranch = "main"
    @State private var dependsOnLayerID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New local stack layer")
                .font(.title2.weight(.bold))
            Text("Model dependency and review state without creating a branch or pull request.")
                .foregroundStyle(.secondary)
            Form {
                Picker("Workspace", selection: $workspaceID) {
                    Text("Select workspace").tag(nil as String?)
                    ForEach(model.snapshot.domains.gitWorkspaces) { workspace in
                        Text(workspace.name).tag(workspace.id as String?)
                    }
                }
                TextField("Layer title", text: $title)
                TextField("Branch", text: $branch)
                TextField("Base branch", text: $baseBranch)
                Picker("Depends on", selection: $dependsOnLayerID) {
                    Text("No layer dependency").tag(nil as String?)
                    ForEach(model.snapshot.operations.gitStackLayers) { layer in
                        Text(layer.title).tag(layer.id as String?)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save layer") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 560, idealHeight: 440)
        .onAppear {
            workspaceID = workspaceID ?? model.snapshot.domains.gitWorkspaces.first?.id
        }
    }

    private var isValid: Bool {
        workspaceID != nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard let workspaceID,
              model.addGitStackLayer(
                workspaceID: workspaceID,
                title: title,
                branch: branch,
                baseBranch: baseBranch,
                dependsOnLayerID: dependsOnLayerID
              ) != nil else { return }
        dismiss()
    }
}

struct NewProviderComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    let availableProviders: [String]
    @State private var title = ""
    @State private var brief = ""
    @State private var selectedProviders: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New provider comparison")
                .font(.title2.weight(.bold))
            Text("Freeze one local brief into separate provider run identities. This form does not start a provider.")
                .foregroundStyle(.secondary)
            TextField("Comparison title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Shared brief", text: $brief, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...10)
            VStack(alignment: .leading, spacing: 9) {
                Text("Providers").font(.headline)
                ForEach(availableProviders, id: \.self) { provider in
                    Toggle(provider, isOn: Binding(
                        get: { selectedProviders.contains(provider) },
                        set: { selected in
                            if selected { selectedProviders.insert(provider) }
                            else { selectedProviders.remove(provider) }
                        }
                    ))
                }
            }
            .panelStyle()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save comparison draft") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 580, idealHeight: 520)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedProviders.count >= 2
    }

    private func save() {
        guard model.createProviderComparison(
            title: title,
            brief: brief,
            providers: Array(selectedProviders)
        ) != nil else { return }
        dismiss()
    }
}

struct NewManagedWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @State private var projectID: String?
    @State private var threadID: String?
    @State private var branch = "kaname/work"
    @State private var baseRevision = "HEAD"

    private let environment = KanameDesktopEnvironment.current

    init(model: DesktopAppModel) {
        self.model = model
        let project = model.snapshot.projects.first { $0.archivedAtUnixMillis == nil && $0.path != nil }
        _projectID = State(initialValue: project?.id)
        _threadID = State(initialValue: project.flatMap { project in
            model.snapshot.threads.first { $0.projectID == project.id && $0.kind == .coding }?.id
        })
    }

    private var projects: [DesktopProject] {
        model.snapshot.projects.filter { $0.archivedAtUnixMillis == nil && $0.path != nil }
    }

    private var threads: [DesktopThread] {
        guard let projectID else { return [] }
        return model.snapshot.threads.filter { $0.projectID == projectID && $0.kind == .coding }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New isolated worktree").font(.title2.weight(.bold))
            Text("Choose the conversation that will own the work. Kaname derives a private destination and asks for exact approval before touching Git.")
                .foregroundStyle(.secondary)
            worktreeFields
            targetPreview
            BoundaryCallout(
                title: "Authority stays narrow",
                detail: "Saving creates a local proposal only. Creation and later cleanup each require a separate approval in Inbox; cleanup refuses a dirty worktree."
            )
            Spacer()
            footer
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 640, idealHeight: 560)
    }

    private var worktreeFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            projectPicker
            threadPicker
            TextField("Branch", text: $branch).textFieldStyle(.roundedBorder)
            TextField("Base revision", text: $baseRevision).textFieldStyle(.roundedBorder)
        }
    }

    private var projectPicker: some View {
        Picker("Project", selection: $projectID) {
            Text("Choose a project").tag(String?.none)
            ForEach(projects) { project in
                Text(project.name).tag(Optional(project.id))
            }
        }
        .onChange(of: projectID) { selected in
            threadID = model.snapshot.threads.first { $0.projectID == selected && $0.kind == .coding }?.id
        }
    }

    private var threadPicker: some View {
        Picker("Coding conversation", selection: $threadID) {
            Text("Choose a conversation").tag(String?.none)
            ForEach(threads) { thread in
                Text(thread.title).tag(Optional(thread.id))
            }
        }
    }

    @ViewBuilder
    private var targetPreview: some View {
        if let target = proposedTarget {
            LabeledContent("Managed destination") {
                Text(target.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .panelStyle()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
            Button("Save proposal") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(proposedTarget == nil)
        }
    }

    private var proposedTarget: URL? {
        guard let projectID, let threadID,
              let project = model.project(id: projectID),
              !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !baseRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let slug = "\(project.name)-\(branch)"
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let digest = String(threadID.prefix(8))
        return environment.worktreeDirectory.appending(path: "\(slug.prefix(80))-\(digest)", directoryHint: .isDirectory)
    }

    private func save() {
        guard let projectID, let threadID,
              let root = model.workspaceURL(threadID: threadID),
              let target = proposedTarget,
              model.proposeWorktree(
                projectID: projectID,
                threadID: threadID,
                rootWorkspacePath: root.path,
                worktreePath: target.path,
                branch: branch,
                baseRevision: baseRevision
              ) != nil else { return }
        dismiss()
    }
}

struct NewEmailDraftSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @State private var selectedAccountID: String?
    @State private var recipients = ""
    @State private var subject = ""
    @State private var draftBody = ""

    init(
        model: DesktopAppModel,
        accountID: String? = nil,
        recipients: String = "",
        subject: String = "",
        body: String = ""
    ) {
        self.model = model
        _selectedAccountID = State(initialValue: accountID ?? model.snapshot.domains.accounts.first {
            $0.service == .gmail && $0.status == .ready
        }?.id)
        _recipients = State(initialValue: recipients)
        _subject = State(initialValue: subject)
        _draftBody = State(initialValue: body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New local email draft")
                .font(.title2.weight(.bold))
            Picker("Gmail account", selection: $selectedAccountID) {
                Text("No account selected").tag(nil as String?)
                ForEach(model.snapshot.domains.accounts.filter { $0.service == .gmail }) { account in
                    Text(account.identity).tag(account.id as String?)
                }
            }
            TextField("Recipients (optional while drafting)", text: $recipients)
                .textFieldStyle(.roundedBorder)
            TextField("Subject", text: $subject)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $draftBody)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 220)
                .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("Save draft only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save draft") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 620, idealHeight: 500)
    }

    private func save() {
        guard model.saveEmailDraft(
            accountID: selectedAccountID,
            recipients: recipients,
            subject: subject,
            body: draftBody
        ) != nil else { return }
        dismiss()
    }
}

struct NewCalendarProposalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @State private var selectedCalendarSourceID: String?
    @State private var title = ""
    @State private var start = Date().addingTimeInterval(3_600)
    @State private var durationMinutes = 30
    @State private var isAllDay = false
    @State private var allDaySpanDays = 1
    @State private var timeZoneIdentifier: String
    @State private var recurrence = "Does not repeat"

    private static func eligibleWritableSources(
        in sources: [DesktopCalendarSourceRecord]
    ) -> [DesktopCalendarSourceRecord] {
        sources.filter { source in
            let access = source.accessLevel.lowercased()
            return source.isEnabled
                && !access.contains("read only")
                && !access.contains("reader")
                && !access.contains("reconnect")
        }
    }

    private var writableSources: [DesktopCalendarSourceRecord] {
        Self.eligibleWritableSources(in: model.snapshot.domains.calendarSources)
    }

    init(model: DesktopAppModel) {
        self.model = model
        let sources = Self.eligibleWritableSources(in: model.snapshot.domains.calendarSources)
        _selectedCalendarSourceID = State(initialValue: sources.first?.id)
        _timeZoneIdentifier = State(initialValue: model.snapshot.preferences.defaultScheduleTimeZoneIdentifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Propose calendar event")
                .font(.title2.weight(.bold))
            Text("This creates a local proposal. It does not request Calendar access or create an event.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Title", text: $title)
                Picker("Calendar", selection: $selectedCalendarSourceID) {
                    Text("Select a calendar").tag(nil as String?)
                    ForEach(writableSources) { source in
                        Text("\(source.displayName) · \(source.ownerIdentity)").tag(source.id as String?)
                    }
                }
                if writableSources.isEmpty {
                    Text("Enable a writable calendar in Settings, or reconnect Google to grant Calendar event changes.")
                        .font(.caption).foregroundStyle(KanameColor.warning)
                }
                Toggle("All-day event", isOn: $isAllDay)
                DatePicker(
                    isAllDay ? "Date" : "Start",
                    selection: $start,
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                    .environment(\.timeZone, TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent)
                if isAllDay {
                    Stepper("Span: \(allDaySpanDays) day(s)", value: $allDaySpanDays, in: 1...7)
                } else {
                    Stepper("Duration: \(durationMinutes) minutes", value: $durationMinutes, in: 5...1_440, step: 5)
                }
                TextField("IANA time zone", text: $timeZoneIdentifier)
                Text("The wall-clock time stays pinned to this zone after travel. Kaname shows the local equivalent elsewhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Recurrence", selection: $recurrence) {
                    Text("Does not repeat").tag("Does not repeat")
                    Text("Daily").tag("Daily")
                    Text("Weekly").tag("Weekly")
                    Text("Monthly").tag("Monthly")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save proposal") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 540, idealHeight: 470)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && TimeZone(identifier: timeZoneIdentifier) != nil
            && selectedCalendarSourceID != nil
    }

    private func save() {
        let source = selectedCalendarSourceID.flatMap { selectedID in
            model.snapshot.domains.calendarSources.first { $0.id == selectedID }
        }
        var pinnedCalendar = Calendar(identifier: .gregorian)
        pinnedCalendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
        let normalizedStart = isAllDay ? pinnedCalendar.startOfDay(for: start) : start
        guard model.createCalendarProposal(
            accountID: source?.accountID,
            calendarSourceID: source?.id,
            title: title,
            startAtUnixMillis: Int64(normalizedStart.timeIntervalSince1970 * 1_000),
            durationMinutes: isAllDay ? allDaySpanDays * 1_440 : durationMinutes,
            timeZoneIdentifier: timeZoneIdentifier,
            recurrence: recurrence,
            isAllDay: isAllDay
        ) != nil else { return }
        dismiss()
    }
}

struct NewAutomationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    let editingID: String?
    @State private var name = ""
    @State private var timeZoneIdentifier: String
    @State private var actionSummary = ""
    @State private var missedRunPolicy = DesktopAutomationRule.MissedRunPolicy.skip
    @State private var frequency = DesktopScheduleSpec.Frequency.weekly
    @State private var scheduledTime = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? .now
    @State private var onceDate = Date().addingTimeInterval(3_600)
    @State private var weekday = 2
    @State private var actionKind = DesktopAutomationActionKind.notification
    @State private var authority = DesktopAutomationAuthority.localOnly
    @State private var projectID: String?
    @State private var selectedSkillIDs: Set<String> = []
    @State private var notificationEnabled = true

    init(model: DesktopAppModel, editing rule: DesktopAutomationRule? = nil) {
        self.model = model
        editingID = rule?.id
        let spec = rule?.scheduleSpec
        _name = State(initialValue: rule?.name ?? "")
        _timeZoneIdentifier = State(initialValue: rule?.timeZoneIdentifier ?? model.snapshot.preferences.defaultScheduleTimeZoneIdentifier)
        _actionSummary = State(initialValue: rule?.actionSummary ?? "")
        _missedRunPolicy = State(initialValue: rule?.missedRunPolicy ?? .skip)
        _frequency = State(initialValue: spec?.frequency ?? .weekly)
        var components = DateComponents(hour: spec?.hour ?? 9, minute: spec?.minute ?? 0)
        components.timeZone = TimeZone(identifier: rule?.timeZoneIdentifier ?? model.snapshot.preferences.defaultScheduleTimeZoneIdentifier)
        _scheduledTime = State(initialValue: Calendar.current.date(from: components) ?? .now)
        _onceDate = State(initialValue: spec?.onceAtUnixMillis.map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? Date().addingTimeInterval(3_600))
        _weekday = State(initialValue: spec?.weekday ?? 2)
        _actionKind = State(initialValue: rule?.actionKind ?? .notification)
        _authority = State(initialValue: rule?.authority ?? .localOnly)
        _projectID = State(initialValue: rule?.projectID)
        _selectedSkillIDs = State(initialValue: Set(rule?.skillIDs ?? []))
        _notificationEnabled = State(initialValue: rule?.notificationEnabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editingID == nil ? "New automation draft" : "Edit automation")
                .font(.title2.weight(.bold))
            Text("Choose a deterministic trigger, one domain-aware action, and its exact authority. The rule remains disabled until review is complete.")
                .foregroundStyle(.secondary)
            Form {
                Section("Trigger") {
                    TextField("Name", text: $name)
                    Picker("Frequency", selection: $frequency) {
                        ForEach(DesktopScheduleSpec.Frequency.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if frequency == .once {
                        DatePicker("Run at", selection: $onceDate)
                    } else {
                        DatePicker("Time", selection: $scheduledTime, displayedComponents: .hourAndMinute)
                        if frequency == .weekly {
                            Picker("Weekday", selection: $weekday) {
                                ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, day in
                                    Text(day).tag(index + 1)
                                }
                            }
                        }
                    }
                    TextField("IANA time zone", text: $timeZoneIdentifier)
                    Picker("Missed run", selection: $missedRunPolicy) {
                        ForEach(DesktopAutomationRule.MissedRunPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Action") {
                    Picker("Kind", selection: $actionKind) {
                        ForEach(DesktopAutomationActionKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Project", selection: $projectID) {
                        Text("No project").tag(String?.none)
                        ForEach(model.snapshot.projects.filter { $0.archivedAtUnixMillis == nil }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("What should happen?", text: $actionSummary, axis: .vertical).lineLimit(2...5)
                    if actionKind == .skill || actionKind == .conversation {
                        Text(actionKind == .skill
                            ? "Choose the registered capability context this read-only run must use."
                            : "Optional registered capability context")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.snapshot.domains.skills.filter(\.enabled)) { skill in
                            Toggle(skill.name, isOn: Binding(
                                get: { selectedSkillIDs.contains(skill.id) },
                                set: { enabled in
                                    if enabled { selectedSkillIDs.insert(skill.id) } else { selectedSkillIDs.remove(skill.id) }
                                }
                            ))
                        }
                    }
                    if actionKind != .notification {
                        Text("Scheduled provider turns run in Kaname's read-only, network-disabled conversation boundary. Selecting a capability supplies frozen, revision-bound context; it does not grant an external tool action.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Authority & attention") {
                    Picker("Authority", selection: $authority) {
                        ForEach(DesktopAutomationAuthority.allCases, id: \.self) { option in
                            if option != .localOnly || actionKind == .notification { Text(option.label).tag(option) }
                        }
                    }
                    Toggle("Notify when this rule completes or needs attention", isOn: $notificationEnabled)
                    Text("Agent conversations and skill runs require either exact approval for every occurrence or a separately approved visible standing rule.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(editingID == nil ? "Save disabled draft" : "Save changes for review") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 650, idealHeight: 700)
        .onChange(of: actionKind) { newValue in
            if newValue != .notification, authority == .localOnly { authority = .askEveryRun }
            if newValue == .notification { selectedSkillIDs.removeAll() }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !actionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && TimeZone(identifier: timeZoneIdentifier) != nil
            && (actionKind != .skill || !selectedSkillIDs.isEmpty)
            && (actionKind == .notification || authority != .localOnly)
    }

    private func save() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: scheduledTime)
        let spec = DesktopScheduleSpec.anchored(
            frequency: frequency,
            hour: components.hour ?? 9,
            minute: components.minute ?? 0,
            weekday: frequency == .weekly ? weekday : nil,
            onceAtUnixMillis: frequency == .once ? Int64(onceDate.timeIntervalSince1970 * 1_000) : nil
        )
        let schedule = DesktopScheduleEngine.humanSchedule(spec: spec, timeZoneIdentifier: timeZoneIdentifier)
        let saved: Bool
        if let editingID {
            saved = model.updateAutomation(
                id: editingID,
                name: name,
                schedule: schedule,
                timeZoneIdentifier: timeZoneIdentifier,
                actionSummary: actionSummary,
                missedRunPolicy: missedRunPolicy,
                scheduleSpec: spec,
                actionKind: actionKind,
                authority: authority,
                projectID: projectID,
                skillIDs: Array(selectedSkillIDs),
                notificationEnabled: notificationEnabled
            )
        } else {
            saved = model.createAutomation(
                name: name,
                schedule: schedule,
                timeZoneIdentifier: timeZoneIdentifier,
                actionSummary: actionSummary,
                missedRunPolicy: missedRunPolicy,
                scheduleSpec: spec,
                actionKind: actionKind,
                authority: authority,
                projectID: projectID,
                skillIDs: Array(selectedSkillIDs),
                toolNames: [],
                notificationEnabled: notificationEnabled
            ) != nil
        }
        guard saved else { return }
        dismiss()
    }
}

struct NewDesktopThreadSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.desktopQALargeText) private var usesQALargeText
    @ObservedObject var model: DesktopAppModel
    let projectID: String?
    let capabilities: [ProviderCapabilitySnapshot]
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: DesktopWorkKind = .coding
    @State private var provider: String
    @State private var runtimeModel: String
    @State private var reasoning: String
    @State private var runtimeMode: ConversationRuntimeMode = .approvalRequired
    @State private var networkAccess = false

    init(
        model: DesktopAppModel,
        projectID: String?,
        capabilities: [ProviderCapabilitySnapshot],
        created: @escaping (String) -> Void
    ) {
        self.model = model
        self.projectID = projectID
        self.capabilities = capabilities
        self.created = created
        _kind = State(initialValue: model.project(id: projectID)?.context.defaultKind ?? .coding)
        let initialProvider = model.project(id: projectID)?.context.defaultProvider ?? "Codex"
        let initialModel = ConversationRuntimeCatalog.selectedModel(
            provider: initialProvider,
            requested: model.project(id: projectID)?.context.defaultModel ?? "Use provider default",
            capabilities: capabilities
        )
        _provider = State(initialValue: initialProvider)
        _runtimeModel = State(initialValue: initialModel)
        _reasoning = State(initialValue: ConversationRuntimeCatalog.selectedReasoning(
            provider: initialProvider,
            model: initialModel,
            capabilities: capabilities
        ))
    }

    private var project: DesktopProject? {
        model.project(id: projectID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Context") {
                    LabeledContent {
                        Text(project?.name ?? "Standalone")
                            .fontWeight(.medium)
                    } label: {
                        Label(
                            project == nil ? "Conversation" : "Project",
                            systemImage: project == nil ? "bubble.left" : "folder.fill"
                        )
                    }
                    Text(
                        project == nil
                            ? "Start without attaching a project. You can connect deliberate context later."
                            : "This conversation stays attached to the selected project."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Kind") {
                    if usesQALargeText || dynamicTypeSize.isAccessibilitySize {
                        kindPicker.pickerStyle(.menu)
                    } else {
                        kindPicker.pickerStyle(.segmented)
                    }
                    Text(kind.startDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ConversationRuntimeEditor(
                    provider: $provider,
                    model: $runtimeModel,
                    reasoning: $reasoning,
                    runtimeMode: $runtimeMode,
                    networkAccess: $networkAccess,
                    capabilities: capabilities,
                    stagedCoding: kind == .coding,
                    initialFocus: .full
                )
                Section {
                    Label("No subject required", systemImage: "sparkles")
                    Text("Kaname opens a blank conversation and names it automatically from your first message.")
                        .foregroundStyle(.secondary)
                    Label(
                        kind == .coding
                            ? "Plan first · read-only · network disabled · explicit isolated implementation approval"
                            : ConversationRuntimeCatalog.boundarySummary(
                                provider: provider,
                                runtimeMode: runtimeMode,
                                networkAccess: networkAccess
                            ),
                        systemImage: kind == .coding
                            ? "checkmark.shield.fill"
                            : (runtimeMode == .fullAccess ? "exclamationmark.shield" : "lock.shield")
                    )
                    .foregroundStyle(kind != .coding && runtimeMode == .fullAccess ? KanameColor.warning : .secondary)
                }
            }
            .formStyle(.grouped)
            .padding(12)
            .navigationTitle("New conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start conversation") {
                        let id = model.createConversation(
                            kind: kind,
                            projectID: projectID,
                            provider: provider,
                            model: runtimeModel,
                            reasoningEffort: reasoning,
                            runtimeMode: runtimeMode,
                            networkAccess: networkAccess
                        )
                        created(id)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(runtimeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .desktopAdaptiveSheet(idealWidth: 620, idealHeight: 720)
    }

    private var kindPicker: some View {
        Picker("Kind", selection: $kind) {
            ForEach(DesktopWorkKind.allCases, id: \.self) { kind in
                Text(kind.label).tag(kind)
            }
        }
    }
}
