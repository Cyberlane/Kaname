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

struct DesktopRenameConversationSheet: View {
    @Binding var title: String
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename conversation").font(.title2.weight(.bold))
            TextField("Conversation title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("A manual title is never replaced by later provider turns.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 440)
    }
}

struct DesktopConversationRuntimeSheet: View {
    @Binding var provider: String
    @Binding var model: String
    @Binding var reasoning: String
    @Binding var runtimeMode: ConversationRuntimeMode
    @Binding var networkAccess: Bool
    let capabilities: [ProviderCapabilitySnapshot]
    let stagedCoding: Bool
    let initialFocus: DesktopConversationRuntimeSheetFocus
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            runtimeHeading
            runtimeForm
            runtimeActions
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 520)
    }

    private var runtimeHeading: some View {
        Group {
            Label("Conversation runtime", systemImage: "slider.horizontal.3")
                .font(.title2.weight(.bold))
            Text(stagedCoding
                ? "Provider, model, and thinking apply to future turns. Coding authority is staged separately: read-only plan first, then one explicitly approved isolated implementation."
                : "These settings apply to future turns in this conversation. Change them whenever no turn is running.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var runtimeForm: some View {
        Form {
            ConversationRuntimeEditor(
                provider: $provider,
                model: $model,
                reasoning: $reasoning,
                runtimeMode: $runtimeMode,
                networkAccess: $networkAccess,
                capabilities: capabilities,
                stagedCoding: stagedCoding,
                initialFocus: initialFocus
            )
        }
        .formStyle(.grouped)
    }

    private var runtimeActions: some View {
        HStack {
            Label(
                stagedCoding
                    ? "Plan first · read-only · network disabled · explicit isolated implementation approval"
                    : ConversationRuntimeCatalog.boundarySummary(
                        provider: provider,
                        runtimeMode: runtimeMode,
                        networkAccess: networkAccess
                    ),
                systemImage: stagedCoding ? "checkmark.shield.fill" : (runtimeMode == .fullAccess ? "exclamationmark.shield" : "lock.shield")
            )
                .font(.caption)
                .foregroundStyle(!stagedCoding && runtimeMode == .fullAccess ? KanameColor.warning : .secondary)
            Spacer()
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

enum ConversationRuntimeCatalog {
    static let providers = ["Codex", "Claude", "OpenCode", "Cursor", "Grok"]

    static func snapshot(
        for provider: String,
        capabilities: [ProviderCapabilitySnapshot]
    ) -> ProviderCapabilitySnapshot? {
        let driver: ProviderDriverKind? = switch provider.lowercased() {
        case "codex": .codex
        case "claude": .claudeAgent
        case "opencode", "open code": .openCode
        case "cursor", "cursor-agent", "cursor agent": .cursorAgent
        case "grok", "grok build": .grokBuild
        default: nil
        }
        return capabilities.first { $0.instance.driver == driver }
    }

    static func models(
        for provider: String,
        capabilities: [ProviderCapabilitySnapshot]
    ) -> [ProviderModel] {
        let discovered = snapshot(for: provider, capabilities: capabilities)?.models ?? []
        return discovered.isEmpty ? fallbackModels(for: provider) : discovered
    }

    /// Providers whose CLI has no model-discovery call still accept a model
    /// flag. These are the aliases the CLI documents; custom IDs remain
    /// available through the custom model sheet.
    static func fallbackModels(for provider: String) -> [ProviderModel] {
        switch provider.lowercased() {
        case "claude":
            let efforts = ["low", "medium", "high", "xhigh", "max"]
            return [
                ProviderModel(id: "fable", displayName: "Claude Fable (latest)", supportedReasoningEfforts: efforts, defaultReasoningEffort: "high"),
                ProviderModel(id: "opus", displayName: "Claude Opus (latest)", supportedReasoningEfforts: efforts, defaultReasoningEffort: "high"),
                ProviderModel(id: "sonnet", displayName: "Claude Sonnet (latest)", supportedReasoningEfforts: efforts, defaultReasoningEffort: "medium"),
                ProviderModel(id: "haiku", displayName: "Claude Haiku (latest)", supportedReasoningEfforts: efforts, defaultReasoningEffort: "low"),
            ]
        default:
            return []
        }
    }

    static func selectedModel(
        provider: String,
        requested: String,
        capabilities: [ProviderCapabilitySnapshot]
    ) -> String {
        guard requested == "Use provider default" else { return requested }
        let models = models(for: provider, capabilities: capabilities)
        return models.first(where: \.isDefault)?.id ?? models.first?.id ?? requested
    }

    static func reasoningEfforts(
        provider: String,
        model: String,
        capabilities: [ProviderCapabilitySnapshot]
    ) -> [String] {
        if let advertised = models(for: provider, capabilities: capabilities)
            .first(where: { $0.id == model })?.supportedReasoningEfforts,
           !advertised.isEmpty {
            return advertised
        }
        switch provider.lowercased() {
        case "codex": return ["minimal", "low", "medium", "high", "xhigh"]
        case "claude": return ["low", "medium", "high", "xhigh", "max"]
        default: return ["minimal", "low", "medium", "high", "max"]
        }
    }

    static func selectedReasoning(
        provider: String,
        model: String,
        current: String? = nil,
        capabilities: [ProviderCapabilitySnapshot]
    ) -> String {
        if let advertised = models(for: provider, capabilities: capabilities).first(where: { $0.id == model }),
           let effort = advertised.defaultReasoningEffort {
            return effort
        }
        let choices = reasoningEfforts(provider: provider, model: model, capabilities: capabilities)
        if let current, choices.contains(current) { return current }
        return choices.contains("medium") ? "medium" : choices.first ?? "medium"
    }

    static func managesNetwork(_ provider: String) -> Bool {
        provider.caseInsensitiveCompare("Codex") == .orderedSame
    }

    static func boundarySummary(
        provider: String,
        runtimeMode: ConversationRuntimeMode,
        networkAccess: Bool
    ) -> String {
        if runtimeMode == .fullAccess {
            return "Full local access, no approval prompts, network on"
        }
        let network = managesNetwork(provider)
            ? (networkAccess ? "network on" : "network off")
            : "network follows \(provider)"
        return "\(DesktopComposerRuntimePresentation.access(runtimeMode).title), \(network)"
    }
}

struct DesktopComposerRuntimeControls: View {
    let thread: DesktopThread
    let capabilities: [ProviderCapabilitySnapshot]
    let isLocked: Bool
    let compact: Bool
    let editDetails: () -> Void
    let update: (String, String, String, ConversationRuntimeMode, Bool) -> Void
    @State private var showsAccessOptions = false

    private var advertisedModels: [ProviderModel] {
        ConversationRuntimeCatalog.models(for: thread.provider, capabilities: capabilities)
    }

    private var modelTitle: String {
        if thread.model == "Use provider default" { return "Provider default" }
        return advertisedModels.first(where: { $0.id == thread.model })?.displayName ?? thread.model
    }

    private var thinkingTitle: String {
        thread.reasoningEffort == "xhigh" ? "Extra high" : thread.reasoningEffort.capitalized
    }

    private var layout: DesktopComposerRuntimeLayout {
        DesktopComposerRuntimePresentation.layout(for: thread.kind, compact: compact)
    }

    private var currentAccess: DesktopComposerAccessPresentation {
        DesktopComposerRuntimePresentation.access(thread.runtimeMode)
    }

    private var providerTint: Color {
        switch thread.provider.lowercased() {
        case "codex": KanameColor.accent
        case "claude": KanameColor.external
        case "opencode", "open code": KanameColor.blocked
        default: .secondary
        }
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { thread.provider },
            set: { provider in
                let selectedModel = ConversationRuntimeCatalog.selectedModel(
                    provider: provider,
                    requested: "Use provider default",
                    capabilities: capabilities
                )
                let reasoning = ConversationRuntimeCatalog.selectedReasoning(
                    provider: provider,
                    model: selectedModel,
                    capabilities: capabilities
                )
                update(
                    provider,
                    selectedModel,
                    reasoning,
                    thread.runtimeMode,
                    ConversationRuntimeCatalog.managesNetwork(provider) ? thread.networkAccess : false
                )
            }
        )
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { thread.model },
            set: { selectedModel in
                update(
                    thread.provider,
                    selectedModel,
                    ConversationRuntimeCatalog.selectedReasoning(
                        provider: thread.provider,
                        model: selectedModel,
                        current: thread.reasoningEffort,
                        capabilities: capabilities
                    ),
                    thread.runtimeMode,
                    thread.networkAccess
                )
            }
        )
    }

    private var reasoningSelection: Binding<String> {
        Binding(
            get: { thread.reasoningEffort },
            set: {
                update(
                    thread.provider,
                    thread.model,
                    $0,
                    thread.runtimeMode,
                    thread.networkAccess
                )
            }
        )
    }

    private var authoritySelection: Binding<ConversationRuntimeMode> {
        Binding(
            get: { thread.runtimeMode },
            set: {
                update(
                    thread.provider,
                    thread.model,
                    thread.reasoningEffort,
                    $0,
                    $0 == .fullAccess ? true : thread.networkAccess
                )
            }
        )
    }

    private var networkSelection: Binding<Bool> {
        Binding(
            get: { thread.runtimeMode == .fullAccess ? true : thread.networkAccess },
            set: {
                update(
                    thread.provider,
                    thread.model,
                    thread.reasoningEffort,
                    thread.runtimeMode,
                    $0
                )
            }
        )
    }

    var body: some View {
        controlRow(compact: compact)
            .controlSize(.small)
    }

    private func controlRow(compact: Bool) -> some View {
        HStack(spacing: 2) {
            providerAndModelMenu(compact: compact)
            if layout.visibleControls.contains(.thinking) {
                controlDivider
                thinkingMenu
            }
            if layout.visibleControls.contains(.access) {
                controlDivider
                accessControl
            }
            if layout.visibleControls.contains(.overflow) {
                controlDivider
                overflowMenu
            }
        }
    }

    private func providerAndModelMenu(compact: Bool) -> some View {
        runtimeMenu(
            title: "\(thread.provider) · \(modelTitle)",
            systemImage: DesktopComposerRuntimePresentation.providerSystemImage(thread.provider),
            maximumWidth: compact ? 190 : 220,
            tint: providerTint,
            accessibilityLabel: "Provider and model, \(thread.provider), \(modelTitle)",
            unlockedHelp: "Choose provider and model"
        ) {
            Section("Provider") {
                Picker("Provider", selection: providerSelection) {
                    ForEach(ConversationRuntimeCatalog.providers, id: \.self) { provider in
                        Text(provider).tag(provider)
                    }
                }
                .disabled(isLocked)
            }
            Section("Model") {
                Picker("Model", selection: modelSelection) {
                    Text("Use provider default").tag("Use provider default")
                    ForEach(advertisedModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                    if thread.model != "Use provider default",
                       !advertisedModels.contains(where: { $0.id == thread.model }) {
                        Text("\(thread.model) (custom)").tag(thread.model)
                    }
                }
                .disabled(isLocked)
            }
            if isLocked {
                Text("Changes unlock when the current turn finishes")
            } else {
                Button("Custom model or provider…", systemImage: "slider.horizontal.3", action: editDetails)
            }
        }
    }

    private var thinkingMenu: some View {
        runtimeMenu(
            title: thinkingTitle,
            systemImage: "brain.head.profile",
            accessibilityLabel: "Thinking, \(thinkingTitle)",
            unlockedHelp: "Choose thinking level"
        ) {
            Picker("Thinking", selection: reasoningSelection) {
                ForEach(
                    ConversationRuntimeCatalog.reasoningEfforts(
                        provider: thread.provider,
                        model: thread.model,
                        capabilities: capabilities
                    ),
                    id: \.self
                ) { effort in
                    Text(effort == "xhigh" ? "Extra high" : effort.capitalized).tag(effort)
                }
                let choices = ConversationRuntimeCatalog.reasoningEfforts(
                    provider: thread.provider,
                    model: thread.model,
                    capabilities: capabilities
                )
                if !choices.contains(thread.reasoningEffort) {
                    Text("\(thinkingTitle) (custom)").tag(thread.reasoningEffort)
                }
            }
            .disabled(isLocked)
            if isLocked {
                Text("Changes unlock when the current turn finishes")
            } else {
                Divider()
                Button("Custom thinking or variant…", systemImage: "slider.horizontal.3", action: editDetails)
            }
        }
    }

    private func runtimeMenu<Content: View>(
        title: String,
        systemImage: String,
        maximumWidth: CGFloat? = nil,
        tint: Color = .secondary,
        accessibilityLabel: String,
        unlockedHelp: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            ComposerRuntimeControlLabel(
                title: title,
                systemImage: systemImage,
                showsChevron: true,
                tint: tint
            )
            .frame(maxWidth: maximumWidth, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(accessibilityLabel)
        .help(isLocked ? "Inspect runtime controls; changes unlock when the current turn finishes." : unlockedHelp)
    }

    private var accessControl: some View {
        Button {
            showsAccessOptions.toggle()
        } label: {
            ComposerRuntimeControlLabel(
                title: currentAccess.title,
                systemImage: currentAccess.systemImage,
                showsChevron: true,
                tint: currentAccess.isWarning ? KanameColor.warning : .secondary
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Access, \(ConversationRuntimeCatalog.boundarySummary(provider: thread.provider, runtimeMode: thread.runtimeMode, networkAccess: thread.networkAccess))"
        )
        .help(isLocked
            ? "Inspect access controls; changes unlock when the current turn finishes."
            : ConversationRuntimeCatalog.boundarySummary(
                provider: thread.provider,
                runtimeMode: thread.runtimeMode,
                networkAccess: thread.networkAccess
            ))
        .popover(isPresented: $showsAccessOptions, arrowEdge: .bottom) {
            DesktopComposerAccessPopover(
                provider: thread.provider,
                selectedMode: thread.runtimeMode,
                networkAccess: thread.networkAccess,
                managesNetwork: ConversationRuntimeCatalog.managesNetwork(thread.provider),
                isLocked: isLocked,
                selectMode: { authoritySelection.wrappedValue = $0 },
                setNetworkAccess: { networkSelection.wrappedValue = $0 },
                editDetails: editDetails
            )
        }
    }

    private var overflowMenu: some View {
        Menu {
            if layout.overflowControls.contains(.thinking) {
                Section("Thinking") {
                    Picker("Thinking", selection: reasoningSelection) {
                        ForEach(
                            ConversationRuntimeCatalog.reasoningEfforts(
                                provider: thread.provider,
                                model: thread.model,
                                capabilities: capabilities
                            ),
                            id: \.self
                        ) { effort in
                            Text(effort == "xhigh" ? "Extra high" : effort.capitalized).tag(effort)
                        }
                    }
                    .disabled(isLocked)
                }
            }
            if layout.overflowControls.contains(.access) {
                Section("Access") {
                    Picker("Access", selection: authoritySelection) {
                        ForEach(ConversationRuntimeMode.allCases, id: \.self) { mode in
                            Text(DesktopComposerRuntimePresentation.access(mode).title).tag(mode)
                        }
                    }
                    .disabled(isLocked)
                    if ConversationRuntimeCatalog.managesNetwork(thread.provider) {
                        Toggle("Network access", isOn: networkSelection)
                            .disabled(isLocked || thread.runtimeMode == .fullAccess)
                        if thread.runtimeMode == .fullAccess {
                            Label("Network is required by Full access", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(KanameColor.warning)
                        }
                    } else {
                        Text("Network controlled by \(thread.provider)")
                    }
                }
            }
            if isLocked {
                Divider()
                Text("Changes unlock when the current turn finishes")
            } else {
                Divider()
                Button("Runtime details…", systemImage: "info.circle", action: editDetails)
            }
        } label: {
            ComposerRuntimeControlLabel(
                title: nil,
                systemImage: "ellipsis",
                showsChevron: false
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("More runtime settings")
        .accessibilityValue(
            layout.overflowControls.contains(.access)
                ? "Thinking \(thinkingTitle), access \(currentAccess.title)"
                : "Thinking \(thinkingTitle)"
        )
        .help(isLocked ? "Inspect runtime controls; changes unlock when the current turn finishes." : "More runtime settings")
    }

    private var controlDivider: some View {
        Rectangle()
            .fill(KanameColor.separator.opacity(0.72))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }
}

private struct ComposerRuntimeControlLabel: View {
    let title: String?
    let systemImage: String
    let showsChevron: Bool
    var tint: Color = .secondary
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            if let title {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .font(.system(size: DesktopComposerPresentation.toolbarPointSize, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, title == nil ? 7 : 8)
        .frame(height: 28)
        .background(
            isHovering ? KanameColor.raised.opacity(0.72) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct DesktopComposerAccessPopover: View {
    let provider: String
    let selectedMode: ConversationRuntimeMode
    let networkAccess: Bool
    let managesNetwork: Bool
    let isLocked: Bool
    let selectMode: (ConversationRuntimeMode) -> Void
    let setNetworkAccess: (Bool) -> Void
    let editDetails: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Access", systemImage: "lock.shield")
                    .font(.headline)
                Text("Choose how much routine work can proceed without stopping for approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            if isLocked {
                Label("Inspecting while the current turn finishes", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            ForEach(ConversationRuntimeMode.allCases, id: \.self) { mode in
                DesktopComposerAccessOptionButton(
                    presentation: DesktopComposerRuntimePresentation.access(mode),
                    isSelected: selectedMode == mode
                ) {
                    selectMode(mode)
                    dismiss()
                }
                .disabled(isLocked)
            }

            Divider()
                .padding(.vertical, 2)

            if managesNetwork {
                Toggle(isOn: Binding(
                    get: { selectedMode == .fullAccess ? true : networkAccess },
                    set: { newValue in setNetworkAccess(newValue) }
                )) {
                    DesktopComposerNetworkAccessLabel(
                        isRequired: selectedMode == .fullAccess
                    )
                }
                .toggleStyle(.switch)
                .disabled(isLocked || selectedMode == .fullAccess)
                .padding(.horizontal, 6)
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Network follows \(provider)")
                            .font(.subheadline.weight(.medium))
                        Text("The provider's native permission mode remains authoritative.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
            }

            Divider()
                .padding(.vertical, 2)

            Button {
                dismiss()
                DispatchQueue.main.async { editDetails() }
            } label: {
                Label("Runtime details…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7)
                    .frame(height: 28)
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .contentShape(Rectangle())
            .accessibilityHint("Opens all conversation runtime settings")
        }
        .padding(10)
        .frame(width: 350)
        .background(KanameColor.surface)
    }
}

private struct DesktopComposerNetworkAccessLabel: View {
    let isRequired: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                Text("Network access")
                    .font(.subheadline.weight(.medium))
            }
            GridRow {
                Color.clear
                    .frame(width: 16, height: 1)
                Text(isRequired
                    ? "Required while Full access is selected."
                    : "Allow this provider to reach network services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DesktopComposerAccessOptionButton: View {
    let presentation: DesktopComposerAccessPresentation
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(presentation.isWarning ? KanameColor.warning : Color.primary)
                    Text(presentation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: presentation.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(presentation.isWarning ? KanameColor.warning : KanameColor.accent)
                    .frame(width: 18, height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(KanameColor.accent)
                        .padding(.top, 3)
                }
            }
            .padding(.trailing, isSelected ? 20 : 0)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? (presentation.isWarning ? KanameColor.warning.opacity(0.12) : KanameColor.accent.opacity(0.12))
                    : (isHovering ? KanameColor.raised.opacity(0.72) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(presentation.title). \(presentation.detail)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct ConversationRuntimeEditor: View {
    private static let customChoice = "__kaname_custom_choice__"
    private enum Field: Hashable { case model }

    @Binding var provider: String
    @Binding var model: String
    @Binding var reasoning: String
    @Binding var runtimeMode: ConversationRuntimeMode
    @Binding var networkAccess: Bool
    let capabilities: [ProviderCapabilitySnapshot]
    let stagedCoding: Bool
    let initialFocus: DesktopConversationRuntimeSheetFocus
    @FocusState private var focusedField: Field?

    private var advertisedModels: [ProviderModel] {
        ConversationRuntimeCatalog.models(for: provider, capabilities: capabilities)
    }

    private var reasoningChoices: [String] {
        ConversationRuntimeCatalog.reasoningEfforts(
            provider: provider,
            model: model,
            capabilities: capabilities
        )
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                model == "Use provider default" || advertisedModels.contains(where: { $0.id == model })
                    ? model
                    : Self.customChoice
            },
            set: { model = $0 == Self.customChoice ? "" : $0 }
        )
    }

    private var reasoningSelection: Binding<String> {
        Binding(
            get: { reasoningChoices.contains(reasoning) ? reasoning : Self.customChoice },
            set: { reasoning = $0 == Self.customChoice ? "" : $0 }
        )
    }

    private var usesCustomModel: Bool {
        model != "Use provider default" && !advertisedModels.contains(where: { $0.id == model })
    }

    private var usesCustomReasoning: Bool {
        !reasoningChoices.contains(reasoning)
    }

    var body: some View {
        Section("Provider & model") {
            Picker("Provider", selection: $provider) {
                ForEach(ConversationRuntimeCatalog.providers, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            if let snapshot = ConversationRuntimeCatalog.snapshot(for: provider, capabilities: capabilities) {
                LabeledContent("Status", value: snapshot.state == .ready ? "Ready" : snapshot.state.rawValue.capitalized)
            }
            Picker("Model", selection: modelSelection) {
                Text("Use provider default").tag("Use provider default")
                ForEach(advertisedModels, id: \.id) { option in
                    Text(option.displayName).tag(option.id)
                }
                Text("Custom…").tag(Self.customChoice)
            }
            .focused($focusedField, equals: .model)
            if usesCustomModel {
                TextField("Custom model ID", text: $model)
            }
            Picker("Thinking", selection: reasoningSelection) {
                ForEach(reasoningChoices, id: \.self) { effort in
                    Text(effort == "xhigh" ? "Extra high" : effort.capitalized).tag(effort)
                }
                Text("Custom…").tag(Self.customChoice)
            }
            if usesCustomReasoning {
                TextField("Custom thinking / variant ID", text: $reasoning)
            }
            Text("Lists come from the provider when available. Choose Custom to enter another model or thinking identifier supported by that provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Authority") {
            if stagedCoding {
                LabeledContent("Planning", value: "Read-only · network disabled")
                LabeledContent("Implementation", value: "Explicit approval · isolated worktree · network disabled")
                Text("Coding authority is not a free-running runtime preference. Kaname stops after the plan and again after evidence collection so you can make each decision deliberately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Permission mode", selection: $runtimeMode) {
                    ForEach(ConversationRuntimeMode.allCases, id: \.self) { mode in
                        Text(DesktopComposerRuntimePresentation.access(mode).title).tag(mode)
                    }
                }
                Text(DesktopComposerRuntimePresentation.access(runtimeMode).detail)
                    .font(.caption)
                    .foregroundStyle(runtimeMode == .fullAccess ? KanameColor.warning : .secondary)
                if ConversationRuntimeCatalog.managesNetwork(provider) {
                    Toggle("Allow network access", isOn: $networkAccess)
                        .disabled(runtimeMode == .fullAccess)
                    if runtimeMode == .fullAccess {
                        Text("Codex full access is unsandboxed, so network access is necessarily on.")
                            .font(.caption)
                            .foregroundStyle(KanameColor.warning)
                    }
                } else {
                    LabeledContent("Network", value: "Provider controlled")
                    Text("\(provider) does not expose a separate enforceable network switch through Kaname's current adapter. Its native permission mode remains authoritative.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: provider) { newProvider in
            model = ConversationRuntimeCatalog.selectedModel(
                provider: newProvider,
                requested: "Use provider default",
                capabilities: capabilities
            )
            reasoning = ConversationRuntimeCatalog.selectedReasoning(
                provider: newProvider,
                model: model,
                capabilities: capabilities
            )
            if !ConversationRuntimeCatalog.managesNetwork(newProvider) { networkAccess = false }
        }
        .onChange(of: model) { newModel in
            reasoning = ConversationRuntimeCatalog.selectedReasoning(
                provider: provider,
                model: newModel,
                current: reasoning,
                capabilities: capabilities
            )
        }
        .onChange(of: runtimeMode) { newMode in
            if newMode == .fullAccess { networkAccess = true }
        }
        .onAppear {
            guard initialFocus == .model else { return }
            DispatchQueue.main.async { focusedField = .model }
        }
    }
}
