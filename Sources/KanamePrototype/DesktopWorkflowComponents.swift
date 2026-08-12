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
