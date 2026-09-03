import SwiftUI
import KanameLocalCore
import KanamePrototypeUI
import KanameDesignSystem

@MainActor
private final class LocalCoreWorkspaceModel: ObservableObject {
    enum State: Equatable {
        case ready
        case loading
        case unavailable
        case failed(String)
    }

    @Published private(set) var state: State = .ready
    @Published private(set) var runs: [LocalCoreRun] = []

    func loadCorpus() {
        guard state != .loading, runs.isEmpty else { return }
        guard let runner = LocalCoreRunner.bundled() else {
            state = .unavailable
            return
        }
        state = .loading
        Task {
            do {
                var loaded: [LocalCoreRun] = []
                for descriptor in LocalCoreScenario.allCases {
                    let report = try await runner.runScenario(descriptor.fixtureID)
                    loaded.append(LocalCoreRun(descriptor: descriptor, report: report))
                }
                runs = loaded
                state = .ready
            } catch {
                state = .failed("The local core did not return a bounded fixture report. No provider or external action was started.")
            }
        }
    }
}

private struct LocalCoreRun: Identifiable, Equatable {
    let descriptor: LocalCoreScenario
    let report: LocalCoreScenarioReport

    var id: String { report.fixtureID }
    var attention: String { report.attention }
}

private enum LocalCoreScenario: String, CaseIterable, Identifiable {
    case f01 = "F-01", f02 = "F-02", f03 = "F-03", f04 = "F-04", f05 = "F-05", f06 = "F-06", f07 = "F-07"
    case f08 = "F-08", f09 = "F-09", f10 = "F-10", f11 = "F-11", f12 = "F-12", f13 = "F-13", f14 = "F-14"

    var id: String { rawValue }
    var fixtureID: String { rawValue }

    var title: String {
        switch self {
        case .f01: "Accepted coding run"
        case .f02: "Idempotent queue admission"
        case .f03: "Crash before admission"
        case .f04: "Dispatch reconciliation"
        case .f05: "Unknown native observation"
        case .f06: "Reconnect deduplication"
        case .f07: "Snapshot retention recovery"
        case .f08: "Stale approval"
        case .f09: "Queue revision conflict"
        case .f10: "Interrupt/completion race"
        case .f11: "Notification ambiguity"
        case .f12: "Scope and egress denial"
        case .f13: "Provider outage"
        case .f14: "Malformed envelope rejection"
        }
    }

    var coverage: String {
        switch self {
        case .f02, .f09: "Queue state is journaled and revision-aware; no queue mutation has provider authority."
        case .f08: "Approval stays local and stale state has no effect."
        case .f04, .f10, .f13: "Health remains visible while local history and review stay available."
        case .f11: "A notification receipt cannot alter task or approval truth."
        case .f12, .f14: "Invalid scope and malformed input fail closed before any adapter action."
        default: "Events, replay, and attention are derived from the same durable local journal."
        }
    }
}

struct LocalCoreWorkspace: View {
    private enum Surface: String, CaseIterable, Identifiable {
        case dashboard, threads, inbox
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @StateObject private var model = LocalCoreWorkspaceModel()
    @State private var surface: Surface = .dashboard
    @State private var selectedRun: LocalCoreRun?
    private let autoLoadsCorpus: Bool

    init(autoLoadsCorpus: Bool = CommandLine.arguments.contains("--load-local-core")) {
        self.autoLoadsCorpus = autoLoadsCorpus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.runs.isEmpty {
                emptyState
            } else {
                Picker("Local projection", selection: $surface) {
                    ForEach(Surface.allCases) { surface in Text(surface.title).tag(surface) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 28)
                .padding(.bottom, 16)

                switch surface {
                case .dashboard: dashboard
                case .threads: threads
                case .inbox: inbox
                }
            }
        }
        .background(KanameColor.canvas)
        .task {
            if autoLoadsCorpus { model.loadCorpus() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Provider-free local core", systemImage: "internaldrive")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(KanameColor.textPrimary)
                    Text("Dashboard, Threads, and Inbox below are three views over one Rust journal/corpus model. This control path has no live provider, account, repository, vault, credential, notification, or phone authority.")
                        .foregroundStyle(KanameColor.textPrimary.opacity(0.78))
                }
                Spacer()
                Button {
                    model.loadCorpus()
                } label: {
                    Label(model.runs.isEmpty ? "Load local corpus" : "Replay local corpus", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(KanameColor.accent)
                .disabled(model.state == .loading)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .ready: EmptyView()
        case .loading:
            HStack { ProgressView(); Text("Replaying the bounded F-01–F-14 local corpus…") }
                .foregroundStyle(KanameColor.active)
                .padding(.horizontal, 28)
        case .unavailable:
            Text("Local core not bundled. Rebuild with Scripts/run-local-core-prototype.sh.")
                .foregroundStyle(KanameColor.warning)
                .padding(.horizontal, 28)
        case let .failed(message):
            Text(message)
                .foregroundStyle(KanameColor.danger)
                .padding(.horizontal, 28)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ready to replay F-01–F-14")
                .font(.headline)
            Text("Each result is generated by the signed local Mach service and the persisted Rust fixture journal. The iPhone and every live integration remain not run.")
                .foregroundStyle(KanameColor.textPrimary.opacity(0.78))
        }
        .padding(28)
    }

    private var dashboard: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(model.runs) { run in
                    Button { selectedRun = run } label: { LocalCoreRunCard(run: run) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .sheet(item: $selectedRun) { run in LocalCoreRunDetail(run: run) }
    }

    private var threads: some View {
        List(model.runs) { run in
            Button { selectedRun = run } label: { LocalCoreThreadRow(run: run) }
                .buttonStyle(.plain)
        }
        .sheet(item: $selectedRun) { run in LocalCoreRunDetail(run: run) }
    }

    private var inbox: some View {
        List {
            ForEach(["needs_response", "needs_review", "running", "failed", "interrupted", "queued"], id: \.self) { attention in
                let matching = model.runs.filter { $0.attention == attention }
                if !matching.isEmpty {
                    Section(attention.replacingOccurrences(of: "_", with: " ").capitalized) {
                        ForEach(matching) { run in
                            Button { selectedRun = run } label: { LocalCoreThreadRow(run: run) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedRun) { run in LocalCoreRunDetail(run: run) }
    }
}

private struct LocalCoreRunCard: View {
    let run: LocalCoreRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(run.report.fixtureID).font(.caption.weight(.bold)); Spacer(); Text(run.attention) }
                .font(.caption)
                .foregroundStyle(KanameColor.accent)
            Text(run.descriptor.title).font(.headline).foregroundStyle(KanameColor.textPrimary)
            Text("Task: \(run.report.taskState) · Health: \(run.report.health)")
                .font(.subheadline).foregroundStyle(KanameColor.textPrimary.opacity(0.78))
            Text("\(run.report.eventCount) journal events · \(run.report.effectCount) fake effects")
                .font(.caption).foregroundStyle(KanameColor.textPrimary.opacity(0.62))
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct LocalCoreThreadRow: View {
    let run: LocalCoreRun

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .foregroundStyle(KanameColor.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(run.report.fixtureID) · \(run.descriptor.title)")
                Text("\(run.report.taskState) · \(run.attention) · \(run.report.health)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

private struct LocalCoreRunDetail: View {
    let run: LocalCoreRun

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(run.report.fixtureID) · \(run.descriptor.title)").font(.title2.bold())
            Text(run.descriptor.coverage).foregroundStyle(.secondary)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow { Text("Task"); Text(run.report.taskState) }
                GridRow { Text("Attention"); Text(run.report.attention) }
                GridRow { Text("Health"); Text(run.report.health) }
                GridRow { Text("Journal events"); Text("\(run.report.eventCount)") }
                GridRow { Text("Fake effects"); Text("\(run.report.effectCount)") }
                GridRow { Text("Unknown native events"); Text("\(run.report.unsupportedEventCount)") }
            }
            Text("This is local-only evidence. It cannot grant provider, repository, account, external, notification, or mobile authority.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(minWidth: 440)
    }
}
