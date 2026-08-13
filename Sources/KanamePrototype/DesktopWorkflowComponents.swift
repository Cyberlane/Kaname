import AppKit
import KanameConnectivity
import KanameDesktop
import KanamePrototypeUI
import SwiftUI
#if canImport(Security)
import Security
#endif

struct WorkflowSchemaFormView: View {
    let fields: [DesktopWorkflowFormField]
    @Binding var values: [String: String]

    var body: some View {
        ForEach(fields) { field in
            VStack(alignment: .leading, spacing: 4) {
                switch field.control {
                case .toggle:
                    Toggle(field.title, isOn: Binding(
                        get: { values[field.pointer] == "true" },
                        set: { values[field.pointer] = $0 ? "true" : "false" }
                    ))
                case .picker:
                    Picker(field.title, selection: valueBinding(field)) {
                        if !field.required { Text("Not set").tag("") }
                        ForEach(field.enumChoices, id: \.self) { choice in
                            Text(displayChoice(choice)).tag(choice)
                        }
                    }
                case .multilineText:
                    TextField(field.title, text: valueBinding(field), prompt: prompt(field), axis: .vertical)
                        .lineLimit(3...8)
                case .number:
                    TextField(field.title, text: valueBinding(field), prompt: prompt(field))
                        .textContentType(.none)
                case .date, .dateTime, .text, .automatic:
                    TextField(field.title, text: valueBinding(field), prompt: prompt(field))
                }
                if let description = field.description {
                    Text(description).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func valueBinding(_ field: DesktopWorkflowFormField) -> Binding<String> {
        Binding(
            get: { values[field.pointer] ?? initialValue(field) },
            set: { values[field.pointer] = $0 }
        )
    }

    private func initialValue(_ field: DesktopWorkflowFormField) -> String {
        guard let value = field.defaultJSON else { return "" }
        return field.control == .picker ? value : displayChoice(value)
    }

    private func prompt(_ field: DesktopWorkflowFormField) -> Text? {
        field.placeholder.map(Text.init)
    }

    private func displayChoice(_ value: String) -> String {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return value }
        return decoded as? String ?? String(describing: decoded)
    }
}

struct WorkflowInstallationSetupSheet: View {
    @ObservedObject var model: DesktopAppModel
    let installation: DesktopWorkflowInstallationRecord
    let accounts: [NativeGoogleAccountSnapshot]
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var bindingValues: [String: String] = [:]
    @State private var captureLevel = DesktopWorkflowMailCaptureLevel.metadataOnly
    @State private var includeAttachments = false
    @State private var settledContent = DesktopWorkflowSettledContentPolicy.purgeOrdinaryContent
    @State private var message: String?
    @State private var loaded = false

    private var revision: DesktopWorkflowRevisionRecord? {
        model.snapshot.operations.workflows.revisions.first { $0.id == installation.workflowRevisionID }
    }

    private var fields: [DesktopWorkflowFormField] {
        guard let schema = revision?.configurationSchema else { return [] }
        return DesktopWorkflowSchemaForm.fields(schemaText: schema, hints: revision?.uiHints ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configure \(installation.name)").font(.title2.weight(.bold))
                    Text("Saving creates immutable local revisions and leaves this installation disabled until every required slot is ready.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    installation.readinessIssues.isEmpty ? "Ready for explicit enablement" : "\(installation.readinessIssues.count) unresolved",
                    systemImage: installation.readinessIssues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption).foregroundStyle(installation.readinessIssues.isEmpty ? Nord.auroraGreen : Nord.auroraYellow)
            }
            .padding(20)
            Divider()
            ScrollView {
                Form {
                    if !fields.isEmpty {
                        Section("Configuration") {
                            WorkflowSchemaFormView(fields: fields, values: $values)
                        }
                    }
                    if let slots = revision?.bindingSlots, !slots.isEmpty {
                        Section("Private bindings") {
                            ForEach(slots) { slot in bindingPicker(slot) }
                            Text("Secret slots store only a Keychain reference name here. Secret bytes never enter the workflow manifest, configuration, logs, or model context.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let dependencies = revision?.dependencies, !dependencies.isEmpty {
                        Section("Dependency lock") {
                            ForEach(dependencies) { dependency in
                                LabeledContent("\(dependency.kind.rawValue.capitalized) · \(dependency.id)") {
                                    Text(resolve(dependency).map { "\($0.version) · locked" } ?? "Unavailable")
                                        .foregroundStyle(resolve(dependency) == nil && dependency.required ? Nord.auroraYellow : .secondary)
                                }
                                Text(dependency.versionRequirement).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Local content lifecycle") {
                        Picker("Mail capture", selection: $captureLevel) {
                            ForEach(DesktopWorkflowMailCaptureLevel.allCases, id: \.self) { Text(captureLabel($0)).tag($0) }
                        }
                        Toggle("Include declared attachments", isOn: $includeAttachments)
                        Picker("After work settles", selection: $settledContent) {
                            Text("Purge ordinary copied content").tag(DesktopWorkflowSettledContentPolicy.purgeOrdinaryContent)
                            Text("Retain until explicit removal").tag(DesktopWorkflowSettledContentPolicy.retainUntilExplicitRemoval)
                        }
                    }
                    if !installation.readinessIssues.isEmpty {
                        Section("Readiness") {
                            ForEach(installation.readinessIssues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.circle.fill").foregroundStyle(Nord.auroraYellow)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .padding(16)
            }
            Divider()
            HStack {
                if let message { Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save disabled", action: save).buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 720, height: 720)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func bindingPicker(_ slot: DesktopWorkflowBindingSlotDefinition) -> some View {
        switch slot.kind {
        case .account:
            Picker(slot.label, selection: binding(slot.id)) {
                Text("Choose account").tag("")
                ForEach(accounts) { account in Text(account.identity).tag(account.id) }
            }
        case .providerResource:
            Picker(slot.label, selection: binding(slot.id)) {
                Text("Choose provider resource").tag("")
                ForEach(model.snapshot.domains.calendarSources.filter(\.isEnabled)) { resource in
                    Text("\(resource.displayName) · \(resource.ownerIdentity)").tag(resource.id)
                }
            }
        case .folder:
            HStack {
                TextField(slot.label, text: binding(slot.id))
                Button("Choose…") { chooseFolder(slotID: slot.id) }
            }
        case .secretReference:
            TextField(slot.label + " reference", text: binding(slot.id), prompt: Text("Keychain item or environment reference name"))
        case .capability:
            Picker(slot.label, selection: binding(slot.id)) {
                Text("Choose capability").tag("")
                ForEach(model.workflowCapabilityInstallations.filter(\.enabled)) { item in Text(item.name).tag(item.capabilityID) }
            }
        case .connector:
            Picker(slot.label, selection: binding(slot.id)) {
                Text("Choose connector").tag("")
                ForEach(model.snapshot.operations.workflows.connectorInstallations.filter { $0.enabled && $0.qualified }) { item in
                    Text(item.name).tag(item.connectorID)
                }
            }
        case .renderer:
            Picker(slot.label, selection: binding(slot.id)) {
                Text("Choose renderer").tag("")
                ForEach(model.snapshot.operations.workflows.rendererInstallations.filter { $0.enabled && $0.qualified }) { item in
                    Text(item.name).tag(item.rendererID)
                }
            }
        case .subflow:
            Picker(slot.label, selection: binding(slot.id)) {
                Text("Choose subflow").tag("")
                ForEach(model.snapshot.operations.workflows.subflows.filter(\.enabled)) { item in Text(item.name).tag(item.subflowID) }
            }
        }
        if !slot.summary.isEmpty { Text(slot.summary).font(.caption2).foregroundStyle(.secondary) }
    }

    private func binding(_ slotID: String) -> Binding<String> {
        Binding(get: { bindingValues[slotID] ?? "" }, set: { bindingValues[slotID] = $0 })
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let configuration = model.currentWorkflowConfiguration(installationID: installation.id),
           let object = try? JSONSerialization.jsonObject(with: Data(configuration.canonicalJSON.utf8)) as? [String: Any] {
            for field in fields {
                let key = String(field.pointer.dropFirst()).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let value = object[key] else { continue }
                values[field.pointer] = display(value)
            }
        }
        if let bindings = model.currentWorkflowBindings(installationID: installation.id) {
            bindingValues = Dictionary(uniqueKeysWithValues: bindings.resolutions.compactMap { resolution in
                resolution.resourceIDs.first.map { (resolution.slotID, $0) }
            })
        }
        if let policy = model.snapshot.operations.workflows.capturePolicyRevisions.first(where: {
            $0.id == installation.currentCapturePolicyRevisionID
        })?.policy {
            captureLevel = policy.mailLevel
            includeAttachments = policy.includeAttachments
        }
        if let policy = model.snapshot.operations.workflows.retentionPolicyRevisions.first(where: {
            $0.id == installation.currentRetentionPolicyRevisionID
        })?.policy {
            settledContent = policy.settledContent
        }
    }

    private func save() {
        guard let revision, let configuration = encodedConfiguration() else {
            message = "Configuration values could not be encoded."
            return
        }
        let slots = revision.bindingSlots ?? []
        let resolutions = slots.compactMap { slot -> DesktopWorkflowBindingResolution? in
            guard let value = bindingValues[slot.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return DesktopWorkflowBindingResolution(
                slotID: slot.id, kind: slot.kind, resourceIDs: [value], displayLabels: [displayLabel(value, kind: slot.kind)]
            )
        }
        let locks = (revision.dependencies ?? []).compactMap(resolve)
        do {
            try model.reviseWorkflowInstallation(
                id: installation.id,
                configuration: configuration,
                bindings: resolutions,
                dependencyLock: locks,
                capturePolicy: DesktopWorkflowCapturePolicy(
                    mailLevel: captureLevel,
                    includeAttachments: includeAttachments,
                    maximumAttachmentBytes: includeAttachments ? 32 * 1_024 * 1_024 : 0,
                    maximumTotalBytes: includeAttachments ? 128 * 1_024 * 1_024 : 0,
                    maximumAttachmentCount: includeAttachments ? 32 : 0
                ),
                retentionPolicy: DesktopWorkflowRetentionPolicy(settledContent: settledContent)
            )
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    private func encodedConfiguration() -> Data? {
        var object: [String: Any] = [:]
        for field in fields {
            let raw = values[field.pointer] ?? ""
            if raw.isEmpty && !field.required { continue }
            let key = String(field.pointer.dropFirst()).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch field.type {
            case "boolean": object[key] = raw == "true"
            case "integer": guard let value = Int(raw) else { return nil }; object[key] = value
            case "number": guard let value = Double(raw) else { return nil }; object[key] = value
            default:
                if field.control == .picker, let data = raw.data(using: .utf8),
                   let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    object[key] = decoded
                } else { object[key] = raw }
            }
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func resolve(_ dependency: DesktopWorkflowDependencyConstraint) -> DesktopWorkflowDependencyLockEntry? {
        switch dependency.kind {
        case .capability:
            return model.workflowCapabilityInstallations.first { $0.capabilityID == dependency.id && $0.enabled }.map {
                DesktopWorkflowDependencyLockEntry(componentID: $0.capabilityID, kind: .capability, version: $0.version, digest: $0.packageDigest)
            }
        case .connector:
            return model.snapshot.operations.workflows.connectorInstallations.first { $0.connectorID == dependency.id && $0.enabled && $0.qualified }.map {
                DesktopWorkflowDependencyLockEntry(componentID: $0.connectorID, kind: .connector, version: $0.version, digest: $0.packageDigest)
            }
        case .renderer:
            return model.snapshot.operations.workflows.rendererInstallations.first { $0.rendererID == dependency.id && $0.enabled && $0.qualified }.map {
                DesktopWorkflowDependencyLockEntry(componentID: $0.rendererID, kind: .renderer, version: $0.version, digest: $0.packageDigest)
            }
        case .subflow:
            return model.snapshot.operations.workflows.subflows.first { $0.subflowID == dependency.id && $0.enabled }.map {
                DesktopWorkflowDependencyLockEntry(componentID: $0.subflowID, kind: .subflow, version: $0.version, digest: $0.manifestDigest)
            }
        case .workflow:
            return model.workflowDefinitions.first { $0.id == dependency.id && $0.enabled }.flatMap { definition in
                model.snapshot.operations.workflows.revisions.first { $0.id == definition.currentRevisionID }.map {
                    DesktopWorkflowDependencyLockEntry(componentID: definition.id, kind: .workflow, version: $0.version, digest: $0.manifestDigest)
                }
            }
        }
    }

    private func chooseFolder(slotID: String) {
        let panel = NSOpenPanel()
        panel.title = "Choose workflow folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { bindingValues[slotID] = panel.url?.standardizedFileURL.path }
    }

    private func display(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    private func displayLabel(_ value: String, kind: DesktopWorkflowBindingSlotKind) -> String {
        if kind == .account { return accounts.first(where: { $0.id == value })?.identity ?? "Selected account" }
        return kind == .secretReference ? "Private reference" : URL(fileURLWithPath: value).lastPathComponent
    }

    private func captureLabel(_ level: DesktopWorkflowMailCaptureLevel) -> String {
        switch level {
        case .metadataOnly: "Metadata only"
        case .allowlistedHeaders: "Allowlisted headers"
        case .selectedBodyParts: "Selected body parts"
        case .fullBody: "Full body when required"
        }
    }
}

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

struct WorkflowConnectorInstallationRow: View {
    @ObservedObject var model: DesktopAppModel
    let connector: DesktopWorkflowConnectorInstallationRecord
    let onConfigure: () -> Void

    private var bindingCount: Int {
        model.snapshot.operations.workflows.connectorBindings.filter {
            $0.connectorID == connector.connectorID && $0.enabled
        }.count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: connector.qualified ? "cable.connector.horizontal" : "cable.connector.slash")
                .foregroundStyle(connector.qualified ? Nord.auroraGreen : Nord.auroraYellow)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(connector.name).font(.subheadline.weight(.semibold))
                Text("\(connector.connectorID) · \(connector.version) · \(connector.trust.rawValue)")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                Text("\(connector.effectKinds.count) effect contract\(connector.effectKinds.count == 1 ? "" : "s") · \(connector.allowedHosts.count) reviewed host\(connector.allowedHosts.count == 1 ? "" : "s") · \(bindingCount) binding\(bindingCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Configure…", action: onConfigure)
            Toggle("Enabled", isOn: Binding(
                get: { connector.enabled },
                set: { _ = model.setWorkflowConnectorEnabled(id: connector.id, enabled: $0) }
            ))
            .labelsHidden()
            .disabled(!connector.qualified || bindingCount == 0)
        }
        .padding(10)
        .background(Nord.polarNight1.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WorkflowConnectorBindingSheet: View {
    @ObservedObject var model: DesktopAppModel
    let connector: DesktopWorkflowConnectorInstallationRecord
    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var secretValues: [String: String] = [:]
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure \(connector.name)").font(.title2.weight(.bold))
            Text("This binding grants only the listed hosts and effect contracts. Secret values are stored in Keychain; workflows receive references, never credentials.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Optional account identity", text: $accountID)
            if !connector.allowedHosts.isEmpty {
                LabeledContent("Network hosts", value: connector.allowedHosts.joined(separator: ", "))
            }
            LabeledContent("Effects", value: connector.effectKinds.joined(separator: ", "))
            ForEach(connector.secretSlots, id: \.self) { slot in
                SecureField("Secret for \(slot)", text: Binding(
                    get: { secretValues[slot, default: ""] },
                    set: { secretValues[slot] = $0 }
                ))
                .textContentType(.password)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Nord.auroraYellow)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save binding", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!connector.secretSlots.allSatisfy {
                        secretValues[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    })
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func save() {
        #if canImport(Security)
        do {
            var references: [String: String] = [:]
            for slot in connector.secretSlots {
                guard let value = secretValues[slot], let data = value.data(using: .utf8), !data.isEmpty else {
                    throw DesktopWorkflowOperationalError.invalidConfiguration("every declared secret is required")
                }
                let reference = "\(connector.connectorID).\(UUID().uuidString.lowercased())"
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "\(KanameDesktopEnvironment.current.bundleIdentifier).workflow-connector",
                    kSecAttrAccount as String: reference,
                ]
                SecItemDelete(query as CFDictionary)
                var addition = query
                addition[kSecValueData as String] = data
                guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
                    throw DesktopWorkflowOperationalError.componentUnavailable
                }
                references[slot] = reference
            }
            guard model.bindWorkflowConnector(
                connectorID: connector.connectorID,
                accountID: accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : accountID,
                secretReferences: references,
                grantedHosts: connector.allowedHosts,
                grantedEffectKinds: connector.effectKinds
            ) != nil else { throw DesktopWorkflowOperationalError.componentUnavailable }
            dismiss()
        } catch { message = error.localizedDescription }
        #else
        message = "Keychain is unavailable on this platform."
        #endif
    }
}

struct WorkflowRendererInstallationRow: View {
    @ObservedObject var model: DesktopAppModel
    let renderer: DesktopWorkflowRendererInstallationRecord

    var body: some View {
        LabeledContent {
            Toggle("Enabled", isOn: Binding(
                get: { renderer.enabled },
                set: { _ = model.setWorkflowRendererEnabled(id: renderer.id, enabled: $0) }
            ))
            .labelsHidden()
            .disabled(!renderer.qualified)
        } label: {
            Label {
                Grid(alignment: .leading, verticalSpacing: 3) {
                    GridRow { Text(renderer.name).font(.subheadline.weight(.semibold)) }
                    GridRow {
                        Text("\(renderer.rendererID) · \(renderer.version)")
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    GridRow {
                        Text([
                            renderer.supportsRecalculation ? "Recalculation" : nil,
                            renderer.supportsRangeSelection ? "Range selection" : nil,
                            renderer.mediaTypes.joined(separator: ", "),
                        ].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } icon: {
                Image(systemName: renderer.qualified ? "rectangle.3.group.fill" : "rectangle.3.group.bubble")
                    .foregroundStyle(renderer.qualified ? Nord.auroraGreen : Nord.auroraYellow)
            }
        }
        .padding(10)
        .background(Nord.polarNight1.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WorkflowQualificationSummaryRow: View {
    let run: DesktopWorkflowQualificationRunRecord

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(run.assertions) { assertion in
                    Label(assertion.detail, systemImage: assertion.passed ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(assertion.passed ? Nord.auroraGreen : Nord.auroraYellow)
                }
                Text("Input artifacts \(run.artifactDigests.count) · output artifacts \(run.outputArtifactDigests.count) · \(run.elapsedMilliseconds) ms")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Label(run.fixtureName, systemImage: run.outcome == .passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(run.outcome == .passed ? Nord.auroraGreen : Nord.auroraYellow)
                Spacer()
                Text(run.componentID).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

struct WorkflowStudioSheet: View {
    private enum Projection: String, CaseIterable { case outline = "Outline"; case canvas = "Canvas"; case source = "Source" }
    @ObservedObject var model: DesktopAppModel
    let draftID: String
    let onPublished: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var steps: [DesktopWorkflowStepDefinition] = []
    @State private var selectedStepID: String?
    @State private var selectedSubflowIDs = Set<String>()
    @State private var selectedTriggers: Set<DesktopWorkflowTriggerKind> = [.manual]
    @State private var selectedPermissions = Set<DesktopWorkflowPermission>()
    @State private var message: String?
    @State private var projection = Projection.outline
    @State private var canvasPositions: [DesktopWorkflowCanvasNodePosition] = []
    @State private var sourceText = ""
    @State private var sourceMessage: String?

    private var draft: DesktopWorkflowStudioDraftRecord? {
        model.snapshot.operations.workflows.studioDrafts.first { $0.id == draftID }
    }

    private var selectedStepIndex: Int? {
        selectedStepID.flatMap { id in steps.firstIndex { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Grid(alignment: .leading, verticalSpacing: 4) {
                    GridRow { Text(draft?.name ?? "Workflow Studio").font(.title2.weight(.bold)) }
                    GridRow {
                        Text("Build a readable outline; Kaname generates and validates the exact graph and permission receipt.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let summary = draft?.validationSummary {
                    Label(summary, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Nord.auroraYellow).frame(maxWidth: 300, alignment: .trailing)
                } else {
                    Label("Ready to publish", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(Nord.auroraGreen)
                }
            }
            .padding(20)
            Divider()
            HSplitView {
                VStack(spacing: 10) {
                    Picker("Projection", selection: $projection) {
                        ForEach(Projection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch projection {
                    case .outline: studioOutline
                    case .canvas:
                        WorkflowStudioCanvas(
                            steps: $steps, positions: $canvasPositions, selection: $selectedStepID,
                            onChange: { save() }
                        )
                    case .source: studioSource
                    }
                }
                .padding(18)
                .frame(minWidth: 430, idealWidth: 520)
                studioInspector.frame(minWidth: 360, idealWidth: 430)
            }
            Divider()
            HStack {
                if let message { Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    if model.undoWorkflowStudioDraft(id: draftID) { load() }
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(draft?.undoHistory?.isEmpty != false)
                Button("Redo", systemImage: "arrow.uturn.forward") {
                    if model.redoWorkflowStudioDraft(id: draftID) { load() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(draft?.redoHistory?.isEmpty != false)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Publish disabled") {
                    save()
                    if let workflowID = model.publishWorkflowStudioDraft(id: draftID) {
                        onPublished(workflowID)
                        dismiss()
                    } else { message = "Resolve the validation summary before publishing." }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft?.validationSummary != nil)
            }
            .padding(16)
        }
        .frame(width: 900, height: 650)
        .onAppear(perform: load)
    }

    private var studioOutline: some View {
        GroupBox {
            List(selection: $selectedStepID) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack {
                        Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        Image(systemName: studioSymbol(step.kind)).foregroundStyle(Nord.frost1).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.name)
                            Text(step.kind.label).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tag(step.id)
                }
                .onMove { source, destination in
                    steps.move(fromOffsets: source, toOffset: destination)
                    save()
                }
                .onDelete { offsets in
                    let removed = Set(offsets.map { steps[$0].id })
                    steps.remove(atOffsets: offsets)
                    for index in steps.indices {
                        steps[index].transitions?.removeAll { removed.contains($0.targetStepID) }
                    }
                    canvasPositions.removeAll { removed.contains($0.stepID) }
                    selectedStepID = steps.first?.id
                    save()
                }
            }
            .listStyle(.inset)
            Text("The default outline is keyboard accessible. A canvas is optional and does not own the graph.")
                .font(.caption2).foregroundStyle(.secondary)
        } label: {
            HStack {
                Text("Outline").font(.headline)
                Spacer()
                Menu("Add step", systemImage: "plus") {
                    ForEach(editableKinds, id: \.self) { kind in
                        Button(kind.label) { addStep(kind) }
                    }
                }
            }
        }
    }

    private var studioSource: some View {
        GroupBox("Canonical manifest source") {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $sourceText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 450)
                    .accessibilityLabel("Workflow manifest source")
                if let sourceMessage {
                    Label(sourceMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Nord.auroraYellow)
                }
                HStack {
                    Button("Reload canonical") { sourceText = model.workflowStudioCanonicalSource(draftID: draftID) ?? "" }
                    Spacer()
                    Button("Validate and apply") {
                        if model.replaceWorkflowStudioDraftSource(id: draftID, source: sourceText) {
                            sourceMessage = nil
                            load()
                        } else {
                            sourceMessage = "Source is invalid, unsafe, oversized, or refers to unavailable capabilities."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder
    private var studioInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let index = selectedStepIndex {
                    Text("Step inspector").font(.headline)
                    TextField("Step name", text: Binding(
                        get: { steps[index].name },
                        set: { steps[index].name = $0; save() }
                    ))
                    Picker("Type", selection: Binding(
                        get: { steps[index].kind },
                        set: { replaceKind(at: index, with: $0) }
                    )) {
                        ForEach(editableKinds, id: \.self) { Text($0.label).tag($0) }
                        Text(DesktopWorkflowStepKind.complete.label).tag(DesktopWorkflowStepKind.complete)
                    }
                    if steps[index].kind != .complete {
                        Picker("Capability", selection: Binding(
                            get: { steps[index].capabilityID ?? "" },
                            set: { steps[index].capabilityID = $0.isEmpty ? nil : $0; save() }
                        )) {
                            Text("Structural step").tag("")
                            ForEach(model.workflowCapabilityInstallations.filter(\.enabled)) { capability in
                                Text(capability.name).tag(capability.capabilityID)
                            }
                        }
                    }
                    Toggle("Blocking", isOn: Binding(
                        get: { steps[index].blocking },
                        set: { steps[index].blocking = $0; save() }
                    ))
                    Toggle("Safe to retry", isOn: Binding(
                        get: { steps[index].isIdempotent },
                        set: { steps[index].isIdempotent = $0; if !$0 { steps[index].retryLimit = 0 }; save() }
                    ))
                    Stepper("Retry limit · \(steps[index].retryLimit)", value: Binding(
                        get: { steps[index].retryLimit },
                        set: { steps[index].retryLimit = $0; save() }
                    ), in: 0...5)
                    studioStepContracts(index: index)
                } else {
                    BoundaryCallout(
                        title: "Choose a step",
                        detail: "Edit one focused stage without losing the workflow outline."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
                Divider()
                Text("Triggers").font(.headline)
                ForEach(DesktopWorkflowTriggerKind.allCases, id: \.self) { trigger in
                    Toggle(trigger.label, isOn: setBinding(trigger, in: $selectedTriggers, minimumOne: true))
                }
                Divider()
                DisclosureGroup("Reusable subflows · \(selectedSubflowIDs.count)") {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.snapshot.operations.workflows.subflows.isEmpty {
                            Text("Installed subflows appear here with an exact version and typed contract.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(model.snapshot.operations.workflows.subflows.filter(\.enabled)) { subflow in
                            Toggle("\(subflow.name) · \(subflow.version)", isOn: Binding(
                                get: { selectedSubflowIDs.contains(subflow.id) },
                                set: { selected in
                                    if selected { selectedSubflowIDs.insert(subflow.id) }
                                    else { selectedSubflowIDs.remove(subflow.id) }
                                    save()
                                }
                            ))
                        }
                    }
                    .padding(.top, 8)
                }
                DisclosureGroup("Authority · \(selectedPermissions.count)") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(DesktopWorkflowPermission.allCases, id: \.self) { permission in
                            Toggle(permission.label, isOn: setBinding(permission, in: $selectedPermissions))
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func studioStepContracts(index: Int) -> some View {
        let stepID = steps[index].id
        DisclosureGroup("Transitions · \(steps[index].transitions?.count ?? 0)") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array((steps[index].transitions ?? []).enumerated()), id: \.offset) { transitionIndex, _ in
                    HStack {
                        Picker("Outcome", selection: Binding(
                            get: { steps[index].transitions?[transitionIndex].outcome ?? .always },
                            set: { steps[index].transitions?[transitionIndex].outcome = $0; save() }
                        )) {
                            ForEach(DesktopWorkflowTransitionOutcome.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Target", selection: Binding(
                            get: { steps[index].transitions?[transitionIndex].targetStepID ?? "" },
                            set: { steps[index].transitions?[transitionIndex].targetStepID = $0; save() }
                        )) {
                            ForEach(steps.filter { $0.id != stepID }) { Text($0.name).tag($0.id) }
                        }
                        Button("Remove", systemImage: "minus.circle") {
                            steps[index].transitions?.remove(at: transitionIndex); save()
                        }
                        .labelStyle(.iconOnly)
                    }
                    let predicateCount = steps[index].transitions?[transitionIndex].predicates.count ?? 0
                    ForEach(0..<predicateCount, id: \.self) { predicateIndex in
                        HStack {
                            TextField("JSON Pointer", text: Binding(
                                get: { steps[index].transitions?[transitionIndex].predicates[predicateIndex].pointer ?? "" },
                                set: { steps[index].transitions?[transitionIndex].predicates[predicateIndex].pointer = $0; save() }
                            ))
                            Picker("Predicate", selection: Binding(
                                get: { steps[index].transitions?[transitionIndex].predicates[predicateIndex].operation ?? .exists },
                                set: { steps[index].transitions?[transitionIndex].predicates[predicateIndex].operation = $0; save() }
                            )) {
                                ForEach(DesktopWorkflowPredicateOperator.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            TextField("Value", text: Binding(
                                get: { steps[index].transitions?[transitionIndex].predicates[predicateIndex].value ?? "" },
                                set: { steps[index].transitions?[transitionIndex].predicates[predicateIndex].value = $0.isEmpty ? nil : $0; save() }
                            ))
                            Button("Remove predicate", systemImage: "minus.circle") {
                                steps[index].transitions?[transitionIndex].predicates.remove(at: predicateIndex); save()
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    Button("Add predicate") {
                        steps[index].transitions?[transitionIndex].predicates.append(.init(pointer: "", operation: .exists)); save()
                    }
                }
                Button("Add transition") {
                    guard let target = steps.first(where: { $0.id != stepID })?.id else { return }
                    if steps[index].transitions == nil { steps[index].transitions = [] }
                    steps[index].transitions?.append(.init(outcome: .always, targetStepID: target)); save()
                }
                .disabled(steps[index].kind == .complete || steps.count < 2)
            }
            .padding(.top, 8)
        }
        DisclosureGroup("Schemas and typed mappings · \(steps[index].inputMappings?.count ?? 0)") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Input schema reference", text: optionalBinding(index, \.inputSchemaReference))
                TextField("Output schema reference", text: optionalBinding(index, \.outputSchemaReference))
                ForEach(Array((steps[index].inputMappings ?? []).enumerated()), id: \.element.id) { mappingIndex, mapping in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Target JSON Pointer", text: Binding(
                                get: { steps[index].inputMappings?[mappingIndex].targetPointer ?? "" },
                                set: { steps[index].inputMappings?[mappingIndex].targetPointer = $0; save() }
                            ))
                            Picker("Source", selection: Binding(
                                get: { steps[index].inputMappings?[mappingIndex].reference.source ?? .trigger },
                                set: { steps[index].inputMappings?[mappingIndex].reference.source = $0; save() }
                            )) {
                                ForEach(DesktopWorkflowDataReferenceSource.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            TextField("Source ID", text: Binding(
                                get: { steps[index].inputMappings?[mappingIndex].reference.sourceID ?? "" },
                                set: { steps[index].inputMappings?[mappingIndex].reference.sourceID = $0.isEmpty ? nil : $0; save() }
                            ))
                            TextField("Source JSON Pointer", text: Binding(
                                get: { steps[index].inputMappings?[mappingIndex].reference.pointer ?? "" },
                                set: { steps[index].inputMappings?[mappingIndex].reference.pointer = $0; save() }
                            ))
                            TextEditor(text: Binding(
                                get: { steps[index].inputMappings?[mappingIndex].reference.schema ?? "" },
                                set: { steps[index].inputMappings?[mappingIndex].reference.schema = $0; save() }
                            ))
                            .font(.system(.caption2, design: .monospaced)).frame(height: 60)
                            Button("Remove mapping", role: .destructive) {
                                steps[index].inputMappings?.remove(at: mappingIndex); save()
                            }
                        }
                    } label: { Text(mapping.id).font(.caption) }
                }
                Button("Add typed mapping") {
                    if steps[index].inputMappings == nil { steps[index].inputMappings = [] }
                    let id = "mapping-\(UUID().uuidString.lowercased().prefix(8))"
                    steps[index].inputMappings?.append(.init(
                        id: id, targetPointer: "/value", reference: .init(id: "ref-\(id)", source: .trigger)
                    )); save()
                }
            }
            .padding(.top, 8)
        }
        DisclosureGroup("Artifacts and state") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((steps[index].artifactInputs ?? []).enumerated()), id: \.offset) { itemIndex, _ in
                    HStack {
                        TextField("Artifact role", text: Binding(
                            get: { steps[index].artifactInputs?[itemIndex].role ?? "" },
                            set: {
                                let required = steps[index].artifactInputs?[itemIndex].required ?? true
                                steps[index].artifactInputs?[itemIndex] = .init(role: $0, required: required); save()
                            }
                        ))
                        Toggle("Required", isOn: Binding(
                            get: { steps[index].artifactInputs?[itemIndex].required ?? true },
                            set: {
                                let role = steps[index].artifactInputs?[itemIndex].role ?? "input"
                                steps[index].artifactInputs?[itemIndex] = .init(role: role, required: $0); save()
                            }
                        ))
                    }
                }
                Button("Add artifact input") {
                    if steps[index].artifactInputs == nil { steps[index].artifactInputs = [] }
                    steps[index].artifactInputs?.append(.init(role: "input")); save()
                }
                ForEach(Array((steps[index].stateInputs ?? []).enumerated()), id: \.offset) { itemIndex, _ in
                    HStack {
                        TextField("Namespace", text: stateBinding(index, itemIndex, namespace: true))
                        TextField("Key", text: stateBinding(index, itemIndex, namespace: false))
                    }
                }
                Button("Add state input") {
                    if steps[index].stateInputs == nil { steps[index].stateInputs = [] }
                    steps[index].stateInputs?.append(.init(namespace: "workflow", key: "value")); save()
                }
            }
            .padding(.top, 8)
        }
        if let policy = steps[index].batchPolicy {
            DisclosureGroup("Batch policy") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Items JSON Pointer", text: Binding(
                        get: { steps[index].batchPolicy?.itemsPointer ?? policy.itemsPointer },
                        set: { steps[index].batchPolicy?.itemsPointer = $0; save() }
                    ))
                    Stepper("Maximum items · \(policy.maximumItems)", value: Binding(
                        get: { steps[index].batchPolicy?.maximumItems ?? policy.maximumItems },
                        set: { steps[index].batchPolicy?.maximumItems = $0; save() }
                    ), in: 1...10_000)
                    Stepper("Maximum concurrency · \(policy.maximumConcurrency)", value: Binding(
                        get: { steps[index].batchPolicy?.maximumConcurrency ?? policy.maximumConcurrency },
                        set: { steps[index].batchPolicy?.maximumConcurrency = $0; save() }
                    ), in: 1...32)
                    Picker("Aggregation", selection: Binding(
                        get: { steps[index].batchPolicy?.aggregation ?? policy.aggregation },
                        set: { steps[index].batchPolicy?.aggregation = $0; save() }
                    )) {
                        ForEach(DesktopWorkflowBatchAggregationPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                .padding(.top, 8)
            }
        }
        if steps[index].reviewContract != nil {
            DisclosureGroup("Review contract") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Title", text: reviewBinding(index, \.title))
                    TextField("Summary", text: reviewBinding(index, \.summary))
                    TextEditor(text: reviewBinding(index, \.inputSchema)).frame(height: 60)
                    TextEditor(text: reviewBinding(index, \.outputSchema)).frame(height: 60)
                }.padding(.top, 8)
            }
        }
        if steps[index].waitContract != nil {
            DisclosureGroup("Wait contract") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Connector", text: waitBinding(index, \.connectorID))
                    TextField("Source", text: waitBinding(index, \.source))
                    Stepper("Timeout · \(steps[index].waitContract?.timeoutSeconds ?? 60)s", value: Binding(
                        get: { steps[index].waitContract?.timeoutSeconds ?? 60 },
                        set: { steps[index].waitContract?.timeoutSeconds = $0; save() }
                    ), in: 60...31_536_000)
                }.padding(.top, 8)
            }
        }
        if steps[index].executionPolicy != nil {
            DisclosureGroup("Execution limits") {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper("Timeout · \(steps[index].executionPolicy?.timeoutSeconds ?? 120)s", value: Binding(
                        get: { steps[index].executionPolicy?.timeoutSeconds ?? 120 },
                        set: { steps[index].executionPolicy?.timeoutSeconds = $0; save() }
                    ), in: 1...3_600)
                    Stepper("Maximum output · \(steps[index].executionPolicy?.maximumOutputBytes ?? 0) bytes", value: Binding(
                        get: { steps[index].executionPolicy?.maximumOutputBytes ?? 1 },
                        set: { steps[index].executionPolicy?.maximumOutputBytes = $0; save() }
                    ), in: 1...(64 * 1_024 * 1_024), step: 1_024)
                }.padding(.top, 8)
            }
        }
        if steps[index].agentPolicy != nil {
            DisclosureGroup("Bounded agent") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Direct effects are always disabled.").font(.caption).foregroundStyle(.secondary)
                    Stepper("Model tokens · \(steps[index].agentPolicy?.maximumModelTokens ?? 256)", value: Binding(
                        get: { steps[index].agentPolicy?.maximumModelTokens ?? 256 },
                        set: { steps[index].agentPolicy?.maximumModelTokens = $0; save() }
                    ), in: 256...200_000, step: 256)
                    Stepper("Tool calls · \(steps[index].agentPolicy?.maximumToolCalls ?? 1)", value: Binding(
                        get: { steps[index].agentPolicy?.maximumToolCalls ?? 1 },
                        set: { steps[index].agentPolicy?.maximumToolCalls = $0; save() }
                    ), in: 1...128)
                }.padding(.top, 8)
            }
        }
    }

    private func optionalBinding(_ index: Int, _ keyPath: WritableKeyPath<DesktopWorkflowStepDefinition, String?>) -> Binding<String> {
        Binding(get: { steps[index][keyPath: keyPath] ?? "" }, set: { steps[index][keyPath: keyPath] = $0.isEmpty ? nil : $0; save() })
    }

    private func reviewBinding(_ index: Int, _ keyPath: WritableKeyPath<DesktopWorkflowReviewContract, String>) -> Binding<String> {
        Binding(get: { steps[index].reviewContract?[keyPath: keyPath] ?? "" }, set: { steps[index].reviewContract?[keyPath: keyPath] = $0; save() })
    }

    private func waitBinding(_ index: Int, _ keyPath: WritableKeyPath<DesktopWorkflowWaitContract, String>) -> Binding<String> {
        Binding(get: { steps[index].waitContract?[keyPath: keyPath] ?? "" }, set: { steps[index].waitContract?[keyPath: keyPath] = $0; save() })
    }

    private func stateBinding(_ index: Int, _ itemIndex: Int, namespace: Bool) -> Binding<String> {
        Binding(
            get: { namespace ? steps[index].stateInputs?[itemIndex].namespace ?? "" : steps[index].stateInputs?[itemIndex].key ?? "" },
            set: { value in
                guard let current = steps[index].stateInputs?[itemIndex] else { return }
                steps[index].stateInputs?[itemIndex] = .init(
                    namespace: namespace ? value : current.namespace,
                    key: namespace ? current.key : value,
                    required: current.required, scope: current.scope ?? .installation
                )
                save()
            }
        )
    }

    private var editableKinds: [DesktopWorkflowStepKind] {
        DesktopWorkflowStepKind.allCases.filter { $0 != .complete }
    }

    private func load() {
        guard let draft else { return }
        selectedTriggers = Set(draft.triggerKinds)
        selectedPermissions = Set(draft.permissions.permissions)
        selectedSubflowIDs = Set(draft.subflows.map { "\($0.subflowID)@\($0.version)" })
        steps = draft.steps
        canvasPositions = draft.canvasPositions ?? defaultCanvasPositions()
        sourceText = model.workflowStudioCanonicalSource(draftID: draftID) ?? ""
        if steps.isEmpty {
            steps = [
                .init(id: "prepare", name: "Prepare input", kind: .classifyEvent,
                      transitions: [.init(outcome: .always, targetStepID: "complete")]),
                .init(id: "complete", name: "Complete", kind: .complete),
            ]
            save()
        }
        selectedStepID = steps.first?.id
    }

    private func addStep(_ kind: DesktopWorkflowStepKind) {
        let id = "step-\(UUID().uuidString.lowercased().prefix(8))"
        let step = DesktopWorkflowStepDefinition(
            id: id, name: kind.label, kind: kind, capabilityID: defaultCapability(for: kind),
            transitions: [.init(outcome: .always, targetStepID: steps.first(where: { $0.kind == .complete })?.id ?? "complete")],
            reviewContract: kind == .humanReview ? defaultReviewContract() : nil,
            waitContract: kind == .waitForEmail ? defaultWaitContract() : nil,
            executionPolicy: defaultExecutionPolicy(for: kind),
            agentPolicy: kind == .agent ? defaultAgentPolicy() : nil,
            batchPolicy: kind == .forEach ? .init() : nil
        )
        if let terminal = steps.firstIndex(where: { $0.kind == .complete }) { steps.insert(step, at: terminal) }
        else { steps.append(step); steps.append(.init(id: "complete", name: "Complete", kind: .complete)) }
        selectedStepID = id
        canvasPositions.append(.init(stepID: id, x: 40, y: Double(canvasPositions.count) * 110 + 40))
        save()
    }

    private func replaceKind(at index: Int, with kind: DesktopWorkflowStepKind) {
        steps[index].kind = kind
        steps[index].capabilityID = defaultCapability(for: kind)
        steps[index].reviewContract = kind == .humanReview ? (steps[index].reviewContract ?? defaultReviewContract()) : nil
        steps[index].waitContract = kind == .waitForEmail ? (steps[index].waitContract ?? defaultWaitContract()) : nil
        steps[index].agentPolicy = kind == .agent ? (steps[index].agentPolicy ?? defaultAgentPolicy()) : nil
        steps[index].batchPolicy = kind == .forEach ? (steps[index].batchPolicy ?? .init()) : nil
        steps[index].executionPolicy = defaultExecutionPolicy(for: kind)
        if kind == .complete {
            steps.removeAll { $0.id != steps[index].id && $0.kind == .complete }
            if let moved = steps.firstIndex(where: { $0.id == selectedStepID }) {
                let terminal = steps.remove(at: moved)
                steps.append(terminal)
            }
        }
        save()
    }

    private func save(recordUndo: Bool = true) {
        guard draft != nil else { return }
        let subflowRecords = model.snapshot.operations.workflows.subflows.filter { selectedSubflowIDs.contains($0.id) }
        let references = subflowRecords.map {
            DesktopWorkflowSubflowReference.pinned(
                subflowID: $0.subflowID, version: $0.version,
                inputSchema: $0.inputSchema, outputSchema: $0.outputSchema
            )
        }
        var permissionSet = selectedPermissions
        subflowRecords.forEach { permissionSet.formUnion($0.permissions.permissions) }
        let capabilities = Set(steps.compactMap(\.capabilityID))
            .union(subflowRecords.flatMap { $0.permissions.capabilityIDs })
        _ = model.updateWorkflowStudioDraft(
            id: draftID, triggerKinds: Array(selectedTriggers), steps: steps,
            permissions: .init(permissions: Array(permissionSet), capabilityIDs: Array(capabilities)),
            subflows: references, canvasPositions: canvasPositions,
            manifestMetadata: draft?.manifestMetadata, recordUndo: recordUndo
        )
        sourceText = model.workflowStudioCanonicalSource(draftID: draftID) ?? sourceText
    }

    private func defaultCapability(for kind: DesktopWorkflowStepKind) -> String? {
        switch kind {
        case .compileContext: "kaname.context.compile"
        case .structuredModel: "kaname.model.structured"
        case .registerArtifact: "kaname.artifact.register"
        case .validate: "kaname.validation.run"
        case .effect: "kaname.connector.effect"
        case .createEmailDraft: "kaname.email.draft"
        case .sendEmail: "kaname.email.send"
        default: nil
        }
    }

    private func defaultExecutionPolicy(for kind: DesktopWorkflowStepKind) -> DesktopWorkflowExecutionPolicy? {
        [.invokeTool, .structuredModel, .effect, .agent, .forEach, .createEmailDraft, .sendEmail].contains(kind)
            ? .init() : nil
    }

    private func defaultAgentPolicy() -> DesktopWorkflowAgentPolicy {
        .init(allowedCapabilityIDs: ["kaname.context.compile"], maximumModelTokens: 8_000, maximumToolCalls: 8, timeoutSeconds: 120, allowDirectEffects: false)
    }

    private func defaultReviewContract() -> DesktopWorkflowReviewContract {
        .init(
            title: "Review result", summary: "Inspect the structured result before continuing.",
            inputSchema: #"{"type":"object"}"#, outputSchema: #"{"type":"object"}"#,
            actions: [.init(id: "approve", label: "Approve", kind: .approve, isPrimary: true),
                      .init(id: "reject", label: "Reject", kind: .reject)]
        )
    }

    private func defaultWaitContract() -> DesktopWorkflowWaitContract {
        .init(connectorID: "kaname.mail", source: "mail", timeoutSeconds: 604_800)
    }

    private func defaultCanvasPositions() -> [DesktopWorkflowCanvasNodePosition] {
        steps.enumerated().map { index, step in
            .init(stepID: step.id, x: Double(index % 3) * 230 + 30, y: Double(index / 3) * 130 + 30)
        }
    }

    private func setBinding<Value: Hashable>(
        _ value: Value,
        in selection: Binding<Set<Value>>,
        minimumOne: Bool = false
    ) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(value) },
            set: { selected in
                if selected { selection.wrappedValue.insert(value) }
                else if !minimumOne || selection.wrappedValue.count > 1 { selection.wrappedValue.remove(value) }
                save()
            }
        )
    }

    private func studioSymbol(_ kind: DesktopWorkflowStepKind) -> String {
        switch kind {
        case .complete: "checkmark.circle"
        case .effect, .sendEmail, .createEmailDraft: "bolt.horizontal.circle"
        case .validate: "checkmark.shield"
        case .structuredModel, .agent: "brain"
        default: "square.stack.3d.forward.dottedline"
        }
    }
}

private struct WorkflowStudioCanvas: View {
    @Binding var steps: [DesktopWorkflowStepDefinition]
    @Binding var positions: [DesktopWorkflowCanvasNodePosition]
    @Binding var selection: String?
    let onChange: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GroupBox("Semantic graph canvas") {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(edges, id: \.id) { edge in
                        Path { path in
                            path.move(to: point(edge.from))
                            path.addLine(to: point(edge.to))
                        }
                        .stroke(Nord.frost0.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: edge.outcome == .always ? [] : [6, 4]))
                        .accessibilityHidden(true)
                    }
                    ForEach(steps) { step in
                        let position = point(step.id)
                        Button {
                            selection = step.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: studioCanvasSymbol(step.kind))
                                    Text(step.name).font(.caption.weight(.semibold)).lineLimit(1)
                                }
                                Text(step.kind.label).font(.caption2).foregroundStyle(.secondary)
                                Text("\(step.transitions?.count ?? 0) route(s)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(width: 190, alignment: .leading)
                            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selection == step.id ? Nord.frost1 : Nord.polarNight3, lineWidth: selection == step.id ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                        .position(x: position.x + 95, y: position.y + 40)
                        .gesture(DragGesture().onChanged { value in
                            setPosition(stepID: step.id, point: value.location)
                        }.onEnded { _ in onChange() })
                        .accessibilityLabel("\(step.name), \(step.kind.label)")
                        .accessibilityValue("\(step.transitions?.count ?? 0) outgoing routes")
                        .accessibilityHint("Selects this workflow step for editing")
                    }
                }
                .frame(width: 1_100, height: 720)
            }
            .accessibilityLabel("Workflow graph canvas. The synchronized outline provides the complete keyboard representation.")
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: positions)
    }

    private struct Edge: Identifiable {
        var id: String { "\(from):\(outcome.rawValue):\(to)" }
        var from: String
        var to: String
        var outcome: DesktopWorkflowTransitionOutcome
    }

    private var edges: [Edge] {
        steps.flatMap { step in
            (step.transitions ?? []).map { .init(from: step.id, to: $0.targetStepID, outcome: $0.outcome) }
        }
    }

    private func point(_ stepID: String) -> CGPoint {
        if let value = positions.first(where: { $0.stepID == stepID }) { return CGPoint(x: value.x, y: value.y) }
        let index = steps.firstIndex(where: { $0.id == stepID }) ?? 0
        return CGPoint(x: Double(index % 4) * 230 + 30, y: Double(index / 4) * 130 + 30)
    }

    private func setPosition(stepID: String, point: CGPoint) {
        let x = max(0, min(900, point.x - 95))
        let y = max(0, min(620, point.y - 40))
        if let index = positions.firstIndex(where: { $0.stepID == stepID }) {
            positions[index].x = x
            positions[index].y = y
        } else {
            positions.append(.init(stepID: stepID, x: x, y: y))
        }
    }

    private func studioCanvasSymbol(_ kind: DesktopWorkflowStepKind) -> String {
        switch kind {
        case .complete: "checkmark.circle"
        case .branch: "arrow.triangle.branch"
        case .forEach: "square.stack.3d.down.right"
        case .effect, .sendEmail, .createEmailDraft: "bolt.horizontal.circle"
        case .humanReview, .requestApproval: "person.crop.circle.badge.checkmark"
        case .waitForEmail: "clock.badge"
        case .validate: "checkmark.shield"
        case .structuredModel, .agent: "brain"
        default: "square.stack.3d.forward.dottedline"
        }
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
        LabeledContent {
            Text(
                [
                    [wait.accountID, wait.conversationID, wait.correlationValue]
                        .compactMap { $0 }.joined(separator: " · "),
                    "Durable correlated subscription",
                ].joined(separator: "\n")
            )
            .font(.caption2).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
        } label: {
            Label("Waiting for \(wait.source) · \(wait.state.rawValue)", systemImage: "envelope.badge.clock")
                .font(.caption.weight(.semibold)).foregroundStyle(Nord.frost1)
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
    let byteCount: Int?
    let validationSummary: String
    let preview: () -> Void
    let exportCopy: () -> Void
    let compareWithCurrent: (() -> Void)?
    let makeCurrent: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: artifact.active ? "doc.fill" : "clock.arrow.circlepath")
                .foregroundStyle(artifact.active ? Nord.frost1 : .secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(artifact.role) · \(artifact.active ? "Current" : "Previous")")
                    .font(.caption.weight(.semibold))
                Text("\(artifact.filename) · \(artifact.artifactDigest.prefix(12))")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                Text([
                    artifact.mediaType,
                    byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
                    "episode \(artifact.episodeID.prefix(8))",
                    "run \(artifact.createdByRunID.prefix(8))",
                    validationSummary,
                ].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Preview", systemImage: "eye", action: preview).labelStyle(.iconOnly)
                .help("Preview \(artifact.filename)")
            Menu {
                Button("Export copy…", systemImage: "square.and.arrow.up", action: exportCopy)
                if let compareWithCurrent {
                    Button("Compare with current", systemImage: "rectangle.split.2x1", action: compareWithCurrent)
                }
                if let makeCurrent {
                    Button("Make current", systemImage: "checkmark.circle", action: makeCurrent)
                }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("Artifact actions")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(8)
        .background(Nord.polarNight1.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
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
