import Foundation
import KanameConnectivity
import KanamePrototypeUI
import SwiftUI
import KanameDesignSystem

@MainActor
private final class NativeProviderDiscussionViewModel: ObservableObject {
    @Published var workspacePath = FileManager.default.currentDirectoryPath
    @Published var prompt = "Review this workspace and propose a concise implementation plan. Do not change files or execute consequential actions."
    @Published private(set) var result: NativeProviderDiscussionResult?
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false

    let driver: NativeProviderDiscussionDriver
    private let service = NativeProviderDiscussionService()

    init(driver: NativeProviderDiscussionDriver) {
        self.driver = driver
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        result = nil
        error = nil
        let workspace = URL(fileURLWithPath: workspacePath)
        _Concurrency.Task {
            do {
                result = try await service.run(driver: driver, prompt: prompt, workspace: workspace)
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
        }
    }
}

struct NativeProviderDiscussionView: View {
    @StateObject private var model: NativeProviderDiscussionViewModel

    init(driver: NativeProviderDiscussionDriver) {
        _model = StateObject(wrappedValue: NativeProviderDiscussionViewModel(driver: driver))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SurfaceHeader(
                    title: "\(model.driver.displayName) discussion",
                    detail: "Native CLI session reuse with a bounded plan-only run",
                    symbol: "bubble.left.and.text.bubble.right.fill"
                ) { EmptyView() }

                BoundaryCallout(
                    title: "No automatic write authority",
                    detail: boundaryDetail
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Workspace").font(.headline)
                    TextField("Local workspace path", text: $model.workspacePath)
                        .textFieldStyle(.roundedBorder)
                    Text("Prompt").font(.headline)
                    TextEditor(text: $model.prompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 150)
                        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Text("Uses your current \(model.driver.displayName) CLI session; Kaname never receives its token.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Start plan-mode discussion", systemImage: "play.fill") {
                            model.run()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .panelStyle()

                if model.isRunning {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Waiting for \(model.driver.displayName)…")
                    }
                    .panelStyle()
                }

                if let result = model.result {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Discussion result", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                            Spacer()
                            if let session = result.sessionIdentifier {
                                Text(session)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Divider()
                        Text(result.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .panelStyle()
                }

                if let error = model.error {
                    BoundaryCallout(title: "\(model.driver.displayName) stopped safely", detail: error)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.canvas)
    }

    private var boundaryDetail: String {
        switch model.driver {
        case .claude:
            "Claude runs with permission mode plan, a bounded budget, and no session persistence."
        case .openCode:
            "OpenCode runs with its plan agent and never receives the --auto permission flag."
        }
    }
}
