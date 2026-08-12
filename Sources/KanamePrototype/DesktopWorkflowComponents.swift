import KanameDesktop
import KanamePrototypeUI
import SwiftUI

struct WorkflowCapabilityInstallationRow: View {
    @ObservedObject var model: DesktopAppModel
    let capability: DesktopWorkflowCapabilityInstallationRecord
    let onTest: (DesktopWorkflowCapabilityInstallationRecord) -> Void

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 8) {
                if capability.runtime == .isolatedProcess {
                    Button("Test…") { onTest(capability) }
                        .disabled(capability.enabled)
                }
                Toggle("Enabled", isOn: Binding(
                    get: { capability.enabled },
                    set: { _ = model.setWorkflowCapabilityEnabled(id: capability.id, enabled: $0) }
                ))
                .labelsHidden()
                .disabled(capability.trust == .kanameBuiltIn || (!capability.lastTestPassed && !capability.enabled))
            }
        } label: {
            Label {
                Grid(alignment: .leading, verticalSpacing: 3) {
                    GridRow { Text(capability.name).font(.subheadline.weight(.semibold)) }
                    GridRow {
                        Text("\(capability.capabilityID) · \(capability.version) · \(capability.trust.label)")
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    GridRow { Text(capability.summary).font(.caption).foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: capability.lastTestPassed ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .foregroundStyle(capability.lastTestPassed ? Nord.auroraGreen : Nord.auroraYellow)
            }
        }
        .padding(10)
        .background(Nord.polarNight1.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WorkflowHumanReviewRow: View {
    let runID: String
    let stepID: String
    let stepName: String
    let onContinue: (String, String) -> Void

    var body: some View {
        LabeledContent {
            Button("Continue after review") { onContinue(runID, stepID) }
                .buttonStyle(.borderedProminent)
        } label: {
            Label(stepName, systemImage: "person.crop.circle.badge.checkmark")
                .font(.caption.weight(.semibold))
        }
        .padding(10)
        .background(Nord.polarNight1.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WorkflowStructuredReviewRow: View {
    let request: DesktopWorkflowReviewRequestRecord
    let resolve: (String, Data) -> Bool
    @State private var editedValue: String
    @State private var validationMessage: String?

    init(
        request: DesktopWorkflowReviewRequestRecord,
        resolve: @escaping (String, Data) -> Bool
    ) {
        self.request = request
        self.resolve = resolve
        _editedValue = State(initialValue: String(data: request.proposedValue, encoding: .utf8) ?? "{}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Label(request.contract.title, systemImage: "person.crop.circle.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Review required").font(.caption2.weight(.semibold)).foregroundStyle(Nord.auroraYellow)
            }
            Text(request.contract.summary).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $editedValue)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 88, maxHeight: 180)
                .padding(6)
                .background(Nord.polarNight0.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Structured review value")
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(Nord.auroraYellow)
            }
            HStack {
                Text("Edits are schema-checked and bound to the recorded decision.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                ForEach(request.contract.actions) { action in
                    if action.isPrimary {
                        Button(action.label) { submit(actionID: action.id) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(action.label) { submit(actionID: action.id) }.buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(12)
        .background(Nord.polarNight1.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Nord.auroraYellow.opacity(0.45)))
    }

    private func submit(actionID: String) {
        guard let data = editedValue.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            validationMessage = "Enter valid JSON before recording this decision."
            return
        }
        validationMessage = resolve(actionID, data) ? nil : "The value does not satisfy this review contract."
    }
}

struct WorkflowWaitRow: View {
    let wait: DesktopWorkflowWaitSubscriptionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Waiting for \(wait.source) · \(wait.state.rawValue)")
                .font(.caption.weight(.semibold)).foregroundStyle(Nord.frost1)
            Divider().opacity(0.35)
            Text([wait.accountID, wait.conversationID, wait.correlationValue].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            Text("Durable correlated subscription").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Nord.polarNight1.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WorkflowAuthorityGrantRow: View {
    let grant: DesktopWorkflowAuthorityGrantRecord
    let setState: (DesktopWorkflowAuthorityGrantState) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: grant.state == .active ? "checkmark.shield.fill" : "pause.circle")
                .foregroundStyle(grant.state == .active ? Nord.auroraGreen : .secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(grant.effectKind) · \(grant.connectorID)").font(.caption.weight(.semibold))
                Text("Up to \(grant.maximumItemsPerExecution) items · \(grant.requiresManualRun ? "manual runs only" : "triggered runs allowed")")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(grant.postcondition).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if grant.state == .active {
                Button("Pause") { setState(.paused) }
            } else if grant.state == .paused {
                Button("Resume") { setState(.active) }
            }
            if grant.state != .revoked {
                Button("Revoke") { setState(.revoked) }
            }
        }
        .padding(10)
        .background(Nord.polarNight1.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WorkflowDatasetSummaryRow: View {
    let definition: DesktopWorkflowDatasetDefinition
    let rowCount: Int

    var body: some View {
        LabeledContent {
            Text("\(rowCount) rows").font(.caption).foregroundStyle(.secondary)
        } label: {
            Label(definition.name, systemImage: "tablecells")
                .font(.caption.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }
}

struct WorkflowKnowledgeReviewRow: View {
    let fact: DesktopWorkflowFactRecord
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("\(fact.key) · \((fact.scope ?? .workItem).label)", systemImage: "lightbulb.min")
                .font(.caption.weight(.semibold))
            Text(fact.value).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Provenance · \(fact.sourceReferenceIDs.count) source reference\(fact.sourceReferenceIDs.count == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Reject", action: onReject)
                Button("Verify", action: onAccept).buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Nord.polarNight1.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WorkflowKnowledgeReviewSection: View {
    let facts: [DesktopWorkflowFactRecord]
    let review: (String, Bool) -> Void

    var body: some View {
        GroupBox("Knowledge to review · excluded until verified") {
            ForEach(facts) { fact in
                WorkflowKnowledgeReviewRow(
                    fact: fact,
                    onAccept: { review(fact.id, true) },
                    onReject: { review(fact.id, false) }
                )
            }
        }
    }
}

struct WorkflowArtifactRoleRow: View {
    let artifact: DesktopWorkflowArtifactRoleRecord

    var body: some View {
        LabeledContent(
            artifact.role,
            value: "\(artifact.filename) · \(artifact.artifactDigest.prefix(12))"
        )
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

struct WorkflowStateRecordRow: View {
    let record: DesktopWorkflowStateRecord

    var body: some View {
        Label(
            "\(record.namespace).\(record.key) · schema v\(record.schemaVersion) · revision \(record.revision) · \(record.scope.label)",
            systemImage: "memorychip"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
