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

struct DesktopThreadInspector: View {
    @ObservedObject var model: DesktopAppModel
    let thread: DesktopThread
    @Binding var selectedRunID: String?
    @Binding var conversationAnchorID: String?
    let requestArchive: (String) -> Void
    @State private var panel: Panel = .outline
    @State private var activityPanel: ActivityPanel = .summary
    @State private var activitySearch = ""
    @State private var activityEventLimit = 400

    private enum Panel: String, CaseIterable, Identifiable {
        case outline
        case context
        var id: String { rawValue }
    }

    private enum ActivityPanel: String, CaseIterable, Identifiable {
        case summary
        case timeline
        case raw
        var id: String { rawValue }
    }

    private var selectedSummary: DesktopConversationRunSummary? {
        guard let selectedRunID,
              let run = model.providerRun(id: selectedRunID),
              run.threadID == thread.id else { return nil }
        return DesktopConversationRunSummary(
            run: run,
            events: model.providerEvents(threadID: thread.id).filter { $0.runID == selectedRunID }
        )
    }

    var body: some View {
        Group {
            if let selectedSummary {
                activityInspector(selectedSummary)
            } else {
                threadInspector
            }
        }
        .onChange(of: thread.id) { _ in
            selectedRunID = nil
            conversationAnchorID = nil
        }
        .onChange(of: selectedRunID) { _ in
            activityPanel = .summary
            activitySearch = ""
            activityEventLimit = 400
        }
    }

    private var threadInspector: some View {
        VStack(spacing: 0) {
            Picker("Thread inspector", selection: $panel) {
                ForEach(Panel.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch panel {
                    case .outline: outline
                    case .context: context
                    }
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder private var outline: some View {
        InspectorTitle(title: "Conversation outline", symbol: "list.bullet.indent")

        VStack(alignment: .leading, spacing: 10) {
            Text("Thread brief").font(.headline)
            if let goal = thread.messages.first(where: { $0.role == .user })?.body {
                Text("Goal").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(goal).font(.subheadline).lineLimit(4)
            }
            Text("Current status").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(thread.summary.isEmpty ? "No current summary." : thread.summary)
                .font(.subheadline).foregroundStyle(.secondary)
            Divider()
            InspectorFact(label: "Messages", value: "\(thread.messages.count)")
            InspectorFact(label: "Runs", value: "\(model.providerRuns(threadID: thread.id).count)")
            InspectorFact(
                label: "Recorded activity",
                value: "\(model.providerEvents(threadID: thread.id).filter { !$0.kind.isTransportOnly }.count)"
            )
        }
        .panelStyle()

        VStack(alignment: .leading, spacing: 8) {
            Text("Turns").font(.headline)
            let userMessages = thread.messages.filter { $0.role == .user }
            if userMessages.isEmpty {
                Text("No user turns yet.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(userMessages.suffix(40).enumerated()), id: \.element.id) { index, message in
                    Button {
                        conversationAnchorID = message.id
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(max(1, userMessages.count - min(40, userMessages.count) + index + 1))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 22, alignment: .trailing)
                            Text(message.body)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                    .accessibilityHint("Jump to this turn in the conversation")
                }
            }
        }
        .panelStyle()

        let runs = DesktopConversationNarrativePresentation.runSummaries(
            runs: model.providerRuns(threadID: thread.id),
            events: model.providerEvents(threadID: thread.id)
        )
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent runs").font(.headline)
                ForEach(runs.suffix(12)) { summary in
                    Button {
                        selectedRunID = summary.id
                    } label: {
                        DesktopInspectorRunLabel(summary: summary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .panelStyle()
        }
    }

    @ViewBuilder private var context: some View {
        InspectorTitle(title: "Thread context", symbol: "sidebar.right")
        VStack(alignment: .leading, spacing: 10) {
            Text(thread.title).font(.headline)
            KanameStatusBadge(
                KanameDesktopStatusPresentation.attention(thread.attention),
                density: .compact
            )
            Divider()
            InspectorFact(label: "Kind", value: thread.kind.label)
            InspectorFact(label: "Provider", value: thread.provider)
            InspectorFact(label: "Model", value: thread.model)
            InspectorFact(label: "Project", value: model.project(id: thread.projectID)?.name ?? "Standalone")
        }
        .panelStyle()

        VStack(alignment: .leading, spacing: 10) {
            Text("Plan").font(.headline)
            if thread.plan.isEmpty {
                Text("No plan recorded yet.").foregroundStyle(.secondary)
            } else {
                ForEach(thread.plan) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.state.symbol).foregroundStyle(item.state.tint)
                        Text(item.title).font(.subheadline)
                    }
                }
            }
        }
        .panelStyle()

        let artifacts = model.snapshot.operations.artifacts.filter { $0.threadID == thread.id }
        VStack(alignment: .leading, spacing: 10) {
            Text("Artifacts").font(.headline)
            if artifacts.isEmpty {
                Text("No artifacts attached.").foregroundStyle(.secondary)
            } else {
                ForEach(artifacts) { artifact in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(artifact.name, systemImage: artifact.kind.symbol)
                            .font(.subheadline.weight(.semibold))
                        Text(artifact.localPath)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .panelStyle()

        VStack(alignment: .leading, spacing: 10) {
            Text("Thread actions").font(.headline)
            Button("Mark complete") { model.setAttention(threadID: thread.id, attention: .completed) }
                .disabled(thread.attention == .completed)
            Button("Archive", role: .destructive) {
                requestArchive(thread.id)
            }
        }
        .panelStyle()
    }

    private func activityInspector(_ summary: DesktopConversationRunSummary) -> some View {
        VStack(spacing: 0) {
            Button {
                selectedRunID = nil
            } label: {
                Label("Outline", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                Text(summary.run.state.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.run.state.tint)
            }
            .padding(14)

            Picker("Run activity", selection: $activityPanel) {
                ForEach(ActivityPanel.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            if activityPanel == .timeline {
                DesktopInspectorSearchField(text: $activitySearch, placeholder: "Filter this run")
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    InspectorTitle(title: "Run activity", symbol: "list.bullet.rectangle")
                    switch activityPanel {
                    case .summary: runSummary(summary)
                    case .timeline: runTimeline(summary)
                    case .raw: runRawEvidence(summary)
                    }
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder private func runSummary(_ summary: DesktopConversationRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.run.provider).font(.headline)
            Text(summary.run.model).font(.subheadline).foregroundStyle(.secondary)
            Divider()
            InspectorFact(label: "Activity", value: "\(summary.activityCount)")
            InspectorFact(label: "Tools", value: "\(summary.toolCount)")
            InspectorFact(label: "Diff updates", value: "\(summary.diffCount)")
            InspectorFact(label: "Reasoning", value: "\(summary.reasoningCount)")
            if let duration = summary.durationLabel { InspectorFact(label: "Duration", value: duration) }
            if let usage = summary.run.tokenUsage { InspectorFact(label: "Tokens", value: "\(usage)") }
        }
        .panelStyle()

        if let error = summary.run.errorSummary, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(KanameColor.danger)
                .textSelection(.enabled)
                .panelStyle()
        }
    }

    @ViewBuilder private func runTimeline(_ summary: DesktopConversationRunSummary) -> some View {
        let query = activitySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? summary.events : summary.events.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
                || $0.nativeType.localizedCaseInsensitiveContains(query)
        }
        let visible = Array(matching.suffix(activityEventLimit))
        if matching.isEmpty {
            Text(query.isEmpty ? "No provider activity was recorded for this run." : "No activity matches this filter.")
                .foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                if matching.count > visible.count {
                    Button("Show \(min(400, matching.count - visible.count)) older events") {
                        activityEventLimit += 400
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
                ForEach(Self.groupedTimelineEvents(visible)) { group in
                    if group.events.count == 1, let event = group.events.first {
                        DesktopInspectorProviderEventRow(event: event)
                    } else {
                        DesktopInspectorEventGroupRow(group: group)
                    }
                }
            }
        }
    }

    /// Consecutive low-signal events of the same kind (stream deltas, response
    /// fragments, tool-result deliveries) collapse into one expandable row.
    fileprivate struct TimelineEventGroup: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let events: [DesktopProviderEventRecord]
    }

    private static func groupKey(_ event: DesktopProviderEventRecord) -> String? {
        switch event.kind {
        case .assistantText: "text"
        case .native: "native:\(event.nativeType)"
        case .reasoning: "reasoning"
        default: nil
        }
    }

    fileprivate static func groupedTimelineEvents(_ events: [DesktopProviderEventRecord]) -> [TimelineEventGroup] {
        var groups: [TimelineEventGroup] = []
        var pending: [DesktopProviderEventRecord] = []
        var pendingKey: String?
        func flush() {
            guard let first = pending.first else { return }
            let title: String = switch first.kind {
            case .assistantText: "Response fragments"
            case .reasoning: "Reasoning updates"
            default: first.title
            }
            groups.append(TimelineEventGroup(
                id: "group-\(first.id)-\(pending.count)",
                title: title,
                symbol: first.kind.timelineSymbol,
                events: pending
            ))
            pending = []
            pendingKey = nil
        }
        for event in events {
            let key = groupKey(event)
            if let key, key == pendingKey {
                pending.append(event)
                continue
            }
            flush()
            pending = [event]
            pendingKey = key
        }
        flush()
        return groups
    }

    @ViewBuilder private func runRawEvidence(_ summary: DesktopConversationRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider identifiers").font(.headline)
            InspectorFact(label: "Turn", value: summary.run.turnID)
            InspectorFact(label: "Run", value: summary.run.id)
            if let value = summary.run.nativeThreadID { InspectorFact(label: "Native thread", value: value) }
            if let value = summary.run.nativeTurnID { InspectorFact(label: "Native turn", value: value) }
            InspectorFact(label: "Brief digest", value: summary.run.briefDigest)
        }
        .textSelection(.enabled)
        .panelStyle()

        let evidenceArtifacts = model.snapshot.operations.artifacts.filter {
            $0.threadID == thread.id && $0.localPath.contains(summary.run.id)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Immutable evidence").font(.headline)
            if evidenceArtifacts.isEmpty {
                Text(summary.run.state == .running
                    ? "The sealed evidence log appears when this run finishes."
                    : "No sealed evidence artifact is registered for this run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidenceArtifacts) { artifact in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(artifact.name, systemImage: "doc.badge.gearshape")
                            .font(.caption.weight(.semibold))
                        Text(artifact.localPath)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("SHA-256 \(artifact.digest)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            if summary.payloadWasTruncated {
                Label("One or more in-workspace payloads were capped; the sealed evidence log remains authoritative.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(KanameColor.warning)
            }
        }
        .panelStyle()
    }
}

private struct DesktopInspectorEventGroupRow: View {
    let group: DesktopThreadInspector.TimelineEventGroup
    @State private var isExpanded = false

    private var timeSpan: String {
        guard let first = group.events.first, let last = group.events.last, last.createdAtUnixMillis > first.createdAtUnixMillis else { return "" }
        let seconds = (last.createdAtUnixMillis - first.createdAtUnixMillis) / 1_000
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.events) { event in
                    DesktopInspectorProviderEventRow(event: event)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: group.symbol).foregroundStyle(.secondary).frame(width: 18)
                Text("\(group.events.count) × \(group.title)")
                    .font(.caption.weight(.semibold))
                Spacer()
                if !timeSpan.isEmpty {
                    Text(timeSpan).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(KanameColor.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(group.events.count) \(group.title)")
    }
}

struct DesktopProjectInspector: View {
    @ObservedObject var model: DesktopAppModel
    let project: DesktopProject

    private var projectThreads: [DesktopThread] {
        model.snapshot.threads.filter { $0.projectID == project.id }
    }

    private var lastFreshness: Int64? {
        let selected = Set(project.context.knowledgeSourceIDs)
        return model.snapshot.domains.knowledgeSources
            .filter { selected.contains($0.id) }
            .compactMap(\.lastReadAtUnixMillis)
            .max()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorTitle(title: "Project context", symbol: "folder.fill")

                VStack(alignment: .leading, spacing: 10) {
                    Text(project.name).font(.headline)
                    Text(project.summary.isEmpty ? "No purpose recorded." : project.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Divider()
                    InspectorFact(label: "Default kind", value: project.context.defaultKind.label)
                    InspectorFact(label: "Provider", value: project.context.defaultProvider)
                    InspectorFact(label: "Model", value: project.context.defaultModel)
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Included context").font(.headline)
                    InspectorStatus(label: "Instructions", value: "\(project.context.instructionReferences.count)", tint: KanameColor.accent)
                    InspectorStatus(label: "Knowledge", value: "\(project.context.knowledgeSourceIDs.count)", tint: KanameColor.accent)
                    InspectorStatus(label: "Skills & tools", value: "\(project.context.skillIDs.count)", tint: KanameColor.blocked)
                    InspectorStatus(label: "Conversations", value: "\(projectThreads.count)", tint: KanameColor.success)
                    if let lastFreshness {
                        HStack {
                            Text("Last source read").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            RelativeTime(unixMillis: lastFreshness).font(.caption)
                        }
                    }
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Boundary").font(.headline)
                    Text("Only the sources selected here may enter a new project conversation by default. A conversation still shows its exact runtime context and asks separately for consequential authority.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .panelStyle()
            }
            .padding(18)
        }
    }
}

struct DesktopContextInspector: View {
    let destination: DesktopDestination
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorTitle(title: "Current context", symbol: destination.symbol)
                VStack(alignment: .leading, spacing: 10) {
                    Text(destination.title)
                        .font(.headline)
                    Text(destination.contextDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Local health")
                        .font(.headline)
                    InspectorStatus(label: "Workspace state", value: "Durable", tint: KanameColor.success)
                    InspectorStatus(label: "External accounts", value: "Disconnected", tint: KanameColor.separator)
                    InspectorStatus(label: "Mobile relay", value: "Clean", tint: KanameColor.active)
                    InspectorStatus(label: "Physical iPhone", value: "Excluded", tint: KanameColor.warning)
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Safety boundary")
                        .font(.headline)
                    Text("Local drafts and navigation are available. Provider execution, workspace writes, devices, accounts, and external effects retain their own explicit gates.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .panelStyle()
            }
            .padding(18)
        }
    }
}

private struct DesktopInspectorRunLabel: View {
    let summary: DesktopConversationRunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            DesktopInspectorRunTitle(summary: summary)
            DesktopInspectorRunActivity(summary: summary)
        }
    }
}

private struct DesktopInspectorRunTitle: View {
    let summary: DesktopConversationRunSummary

    var body: some View {
        Label(summary.run.provider, systemImage: summary.run.state.accessibilitySymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(summary.run.state.tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
    }
}

private struct DesktopInspectorRunActivity: View {
    let summary: DesktopConversationRunSummary

    var body: some View {
        Text(summary.conciseActivityLabel)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 24)
    }
}

private struct DesktopInspectorProviderEventRow: View {
    let event: DesktopProviderEventRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            DesktopInspectorProviderEventTitle(event: event)
            DesktopInspectorProviderEventDetail(event: event)
        }
        .padding(8)
        .background(event.kind.timelineTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct DesktopInspectorProviderEventTitle: View {
    let event: DesktopProviderEventRecord

    var body: some View {
        Text(event.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(event.kind.timelineTint)
            .padding(.leading, 26)
            .overlay(alignment: .leading) {
                Image(systemName: event.kind.timelineSymbol)
                    .frame(width: 18)
            }
            .overlay(alignment: .trailing) {
                RelativeTime(unixMillis: event.createdAtUnixMillis)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
    }
}

private struct DesktopInspectorProviderEventDetail: View {
    let event: DesktopProviderEventRecord

    @ViewBuilder var body: some View {
        if !event.detail.isEmpty {
            Text(event.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 26)
        }
    }
}

struct DesktopInspectorSearchField: View {
    @Binding var text: String
    var placeholder = "Search Kaname"
    var focusOnAppear = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: KanameSpacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(KanameColor.textSecondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($searchFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(KanameColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .kanameMinimumInteractiveTarget()
            }
        }
        .padding(.horizontal, KanameSpacing.medium)
        .frame(minHeight: KanameSize.minimumInteractiveTarget)
        .background(
            KanameColor.canvas,
            in: RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous)
                .stroke(KanameColor.separator, lineWidth: 1)
        }
        .onAppear {
            guard focusOnAppear else { return }
            DispatchQueue.main.async { searchFocused = true }
        }
    }
}
