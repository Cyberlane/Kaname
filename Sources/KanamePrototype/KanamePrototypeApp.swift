import SwiftUI
import KanameDomain
import KanameFixtures

@main
struct KanamePrototypeApp: App {
    var body: some Scene {
        WindowGroup {
            PrototypeWorkspace()
        }
    }
}

private struct PrototypeWorkspace: View {
    @State private var selectedFixtureName = Phase0Fixtures.codingReview.name
    @State private var selectedView: PrototypeView = .thread

    private var selectedFixture: Phase0Fixture {
        Phase0Fixtures.all.first { $0.name == selectedFixtureName }
            ?? Phase0Fixtures.codingReview
    }

    var body: some View {
        NavigationSplitView {
            List(Phase0Fixtures.all, id: \.name) { fixture in
                Button {
                    selectedFixtureName = fixture.name
                } label: {
                    FixtureRow(fixture: fixture)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    fixture.name == selectedFixtureName ? Color.accentColor.opacity(0.16) : Color.clear
                )
            }
            .navigationTitle("Kaname")
        } content: {
            Group {
                switch selectedView {
                case .thread:
                    ThreadView(fixture: selectedFixture)
                case .inbox:
                    InboxView()
                case .dashboard:
                    DashboardView()
                }
            }
            .navigationTitle(selectedView.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("View", selection: $selectedView) {
                        ForEach(PrototypeView.allCases) { view in
                            Text(view.title).tag(view)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        } detail: {
            ContextInspector(fixture: selectedFixture)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private enum PrototypeView: CaseIterable, Identifiable {
    case thread
    case inbox
    case dashboard

    var id: Self { self }

    var title: String {
        switch self {
        case .thread: "Thread"
        case .inbox: "Inbox"
        case .dashboard: "Dashboard"
        }
    }
}

private struct FixtureRow: View {
    let fixture: Phase0Fixture

    var body: some View {
        let projection = (try? fixture.makeProjection())

        VStack(alignment: .leading, spacing: 4) {
            Text(fixture.thread.title)
                .lineLimit(1)
            Text(projection?.attention.displayName ?? "Unknown")
                .font(.caption)
                .foregroundStyle(projection?.attention.tint ?? .secondary)
        }
    }
}

private struct ThreadView: View {
    let fixture: Phase0Fixture

    var body: some View {
        let projection = (try? fixture.makeProjection())

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fixture.thread.title)
                        .font(.title2.weight(.semibold))
                    Text("\(fixture.providerSession.provider) · \(projection?.taskState.displayName ?? "Unknown")")
                        .foregroundStyle(.secondary)
                }

                if !fixture.approvals.isEmpty {
                    ForEach(fixture.approvals, id: \.id) { approval in
                        ApprovalCard(approval: approval)
                    }
                }

                ForEach(fixture.events, id: \.id) { event in
                    EventRow(event: event)
                }

                if !fixture.queueItems.isEmpty {
                    QueueCard(queueItems: fixture.queueItems)
                }
            }
            .padding()
        }
    }
}

private struct InboxView: View {
    var body: some View {
        List(Phase0Fixtures.all, id: \.name) { fixture in
            let projection = try? fixture.makeProjection()

            HStack(spacing: 12) {
                Circle()
                    .fill((projection?.attention ?? .none).tint)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fixture.thread.title)
                    Text((projection?.attention ?? .none).displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(fixture.thread.workspaceKind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DashboardView: View {
    var body: some View {
        List {
            ForEach(AttentionState.dashboardOrder, id: \.self) { attention in
                let fixtures = Phase0Fixtures.all.filter {
                    (try? $0.makeProjection())?.attention == attention
                }

                if !fixtures.isEmpty {
                    Section(attention.displayName) {
                        ForEach(fixtures, id: \.name) { fixture in
                            Text(fixture.thread.title)
                        }
                    }
                }
            }
        }
    }
}

private struct ApprovalCard: View {
    let approval: Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approval \(approval.status.displayName)", systemImage: "checkmark.shield")
                .font(.headline)
            Text(approval.action.displayName)
            Text("Target: \(approval.target)")
                .foregroundStyle(.secondary)
            Text("Consequence: \(approval.consequence)")
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EventRow: View {
    let event: EventEnvelope

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.symbolName)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.kind.displayName)
                if let nativeType = event.origin.nativeType {
                    Text(nativeType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("#\(event.sequence)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct QueueCard: View {
    let queueItems: [QueueItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Offline queue", systemImage: "tray.full")
                .font(.headline)
            ForEach(queueItems, id: \.id) { item in
                Text(item.body)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ContextInspector: View {
    let fixture: Phase0Fixture

    var body: some View {
        let projection = try? fixture.makeProjection()

        List {
            Section("Context") {
                LabeledContent("Workspace", value: fixture.thread.workspaceKind.displayName)
                LabeledContent("Task", value: fixture.task.title)
                LabeledContent("Provider", value: fixture.providerSession.provider)
            }
            Section("State") {
                LabeledContent("Attention", value: projection?.attention.displayName ?? "Unknown")
                LabeledContent("Run", value: projection?.taskState.displayName ?? "Unknown")
                LabeledContent("Event cursor", value: "\(projection?.latestSequence ?? 0)")
            }
            Section("Evidence") {
                Text("Provider completion and accepted work are separate states.")
            }
        }
        .navigationTitle("Inspector")
    }
}

private extension TaskState {
    var displayName: String {
        switch self {
        case .notStarted: "Not started"
        case .queued: "Queued"
        case .starting: "Starting"
        case .running: "Running"
        case .waitingForUser: "Waiting for you"
        case .completed: "Completed"
        case .accepted: "Accepted"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }
}

private extension AttentionState {
    static let dashboardOrder: [AttentionState] = [
        .needsResponse,
        .needsReview,
        .running,
        .queued,
        .failed,
        .interrupted,
    ]

    var displayName: String {
        switch self {
        case .none: "No attention needed"
        case .queued: "Queued"
        case .running: "Running"
        case .needsResponse: "Needs response"
        case .needsReview: "Needs review"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }

    var tint: Color {
        switch self {
        case .none: .secondary
        case .queued: .blue
        case .running: .mint
        case .needsResponse, .needsReview: .orange
        case .failed: .red
        case .interrupted: .purple
        }
    }
}

private extension ApprovalAction {
    var displayName: String {
        switch self {
        case .codeChange: "Code change"
        case .sendEmail: "Send email"
        case .modifyCalendar: "Modify calendar"
        }
    }
}

private extension ApprovalStatus {
    var displayName: String {
        rawValue.capitalized
    }
}

private extension WorkspaceKind {
    var displayName: String {
        rawValue.capitalized
    }
}

private extension EventKind {
    var displayName: String {
        switch self {
        case .taskQueued: "Task queued"
        case .runStarting: "Run starting"
        case .runStarted: "Run started"
        case .approvalRequested: "Approval requested"
        case .approvalApproved: "Approval approved"
        case .approvalRejected: "Approval rejected"
        case .providerCompleted: "Provider completed"
        case .workAccepted: "Work accepted"
        case .runFailed: "Run failed"
        case .runCancelled: "Run cancelled"
        case .runInterrupted: "Run interrupted"
        case .nativeProviderEvent: "Native provider event"
        }
    }

    var symbolName: String {
        switch self {
        case .taskQueued: "clock"
        case .runStarting, .runStarted: "play.circle"
        case .approvalRequested: "checkmark.shield"
        case .approvalApproved: "checkmark.circle"
        case .approvalRejected: "xmark.circle"
        case .providerCompleted: "checkmark.seal"
        case .workAccepted: "checkmark.seal.fill"
        case .runFailed: "exclamationmark.triangle"
        case .runCancelled, .runInterrupted: "pause.circle"
        case .nativeProviderEvent: "wrench.and.screwdriver"
        }
    }
}
