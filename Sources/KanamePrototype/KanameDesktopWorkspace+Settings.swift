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

struct DesktopSkillsView: View {
    @ObservedObject var model: DesktopAppModel
    @State private var query = ""
    @State private var discovered: [SkillRegistryEntry] = []
    @State private var registerMessage: String?

    /// SKILL.md files on disk (home skill roots plus every project workspace)
    /// that the catalog does not know yet.
    private func refreshDiscovered() {
        let roots = model.snapshot.projects.compactMap { $0.path.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        var seen = Set<String>()
        var entries: [SkillRegistryEntry] = []
        for entry in SkillRegistryLoader.loadRegistry(workspaceRoot: nil) + roots.flatMap({ SkillRegistryLoader.loadRegistry(workspaceRoot: $0) }) {
            guard seen.insert(entry.path).inserted else { continue }
            entries.append(entry)
        }
        let registered = Set(model.snapshot.domains.skills.compactMap(\.registryName))
        discovered = entries.filter { !registered.contains($0.name) }.sorted { $0.name < $1.name }
    }

    private var filteredSkills: [DesktopSkillRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return model.snapshot.domains.skills }
        return model.snapshot.domains.skills.filter {
            $0.name.lowercased().contains(normalized)
                || $0.kind.label.lowercased().contains(normalized)
                || $0.scope.lowercased().contains(normalized)
                || $0.source.lowercased().contains(normalized)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Section {
                    if filteredSkills.isEmpty {
                        EmptyPanel(
                            symbol: "hammer",
                            title: "No matching skills or tools",
                            detail: "Search by name, kind, source, or scope."
                        )
                        .frame(minHeight: 220)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                            ForEach(filteredSkills) { skill in
                                VStack(alignment: .leading, spacing: 11) {
                                    HStack {
                                        Image(systemName: skill.kind.symbol)
                                            .font(.title2)
                                            .foregroundStyle(skill.enabled ? KanameColor.accent : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(skill.name).font(.headline)
                                            Text(skill.kind.label)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Toggle("Enabled", isOn: Binding(
                                            get: { skill.enabled },
                                            set: { model.setSkillEnabled(id: skill.id, enabled: $0) }
                                        ))
                                        .labelsHidden()
                                    }
                                    Divider()
                                    LabeledContent("Scope", value: skill.scope)
                                    LabeledContent("Source", value: skill.source)
                                    LabeledContent("Revision", value: skill.revision)
                                    HStack {
                                        Text("Trust")
                                        Spacer()
                                        KanameStatusBadge(
                                            KanameDesktopStatusPresentation.record(skill.status),
                                            density: .compact
                                        )
                                    }
                                }
                                .font(.caption)
                                .panelStyle()
                            }
                        }
                    }
                    if !discovered.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Discovered on disk, not in the catalog")
                                .font(.headline)
                            Text("These SKILL.md files are already usable from the composer with $name. Register them so they also appear here and in search.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(discovered) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name).font(.subheadline.weight(.semibold))
                                        Text(entry.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Text(entry.path).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Button("Register") {
                                        if model.registerDiscoveredSkill(registryName: entry.name, path: entry.path, description: entry.description) != nil {
                                            registerMessage = "Registered \(entry.name)."
                                        } else {
                                            registerMessage = "Could not register \(entry.name)."
                                        }
                                        refreshDiscovered()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(10)
                                .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
                            }
                            if let registerMessage {
                                Text(registerMessage).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .panelStyle()
                    }
                    BoundaryCallout(
                        title: "Updates are reviewable",
                        detail: "Behavioral instructions and executables are pinned with source, revision, licence, requested capabilities, and a diff before installation or activation."
                    )
                } header: {
                    SurfaceHeader(
                        title: "Skills & Tools",
                        detail: "Progressive disclosure, provenance, scope, permissions, and update review",
                        symbol: DesktopDestination.skills.symbol
                    ) {
                        TextField("Search skills and tools", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .accessibilityLabel("Search skills and tools")
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.canvas)
        .onAppear(perform: refreshDiscovered)
        .onChange(of: model.snapshot.domains.skills.count) { _ in refreshDiscovered() }
    }
}

struct DesktopDevicesView: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Devices & Remote",
                    detail: "Encrypted reachability, recovery, and device authority",
                    symbol: DesktopDestination.devices.symbol
                )

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 360), spacing: 14)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    DeviceEndpointCard(
                        symbol: "desktopcomputer",
                        title: "This Mac",
                        subtitle: "Configured foundation",
                        status: "Current health not checked",
                        tint: KanameColor.warning,
                        facts: [
                            ("Intended role", "Execution host and authority"),
                            ("Storage policy", "Local 0700 / 0600"),
                            ("Probe", "Not run in this workspace"),
                        ]
                    )
                    DeviceEndpointCard(
                        symbol: "iphone",
                        title: "iPhone companion",
                        subtitle: "Physical qualification deferred",
                        status: "Simulator and device checks not run",
                        tint: KanameColor.warning,
                        facts: [
                            ("Physical device", "Not selected or checked"),
                            ("Simulator", "Qualification not run"),
                            ("APNs", "Configuration and delivery not checked"),
                        ]
                    )
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 230), spacing: 14)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    RemoteStatusCard(
                        title: "Ciphertext relay",
                        status: model.snapshot.remote.relayStatus,
                        detail: "Foundation for authenticated envelope storage. No hosted-state or cleanup result is implied.",
                        symbol: "network.badge.shield.half.filled",
                        tint: KanameColor.warning
                    )
                    RemoteStatusCard(
                        title: "Notifications",
                        status: model.snapshot.remote.notificationStatus,
                        detail: "The foundation limits APNs to an attention hint; delivery and payload checks require evidence.",
                        symbol: "bell.badge.fill",
                        tint: KanameColor.warning
                    )
                    RemoteStatusCard(
                        title: "Reconciliation",
                        status: model.snapshot.remote.queueStatus,
                        detail: "The recovery contract is implemented as a foundation; queue and receipt behavior is not assumed.",
                        symbol: "arrow.triangle.2.circlepath.circle.fill",
                        tint: KanameColor.warning
                    )
                }

                SectionHeading(title: "Qualification timeline", detail: "Direct evidence and explicit not-run boundaries.")
                VStack(spacing: 0) {
                    ForEach(Array(model.snapshot.remote.events.enumerated()), id: \.element.id) { index, event in
                        RemoteTimelineRow(event: event, isLast: index == model.snapshot.remote.events.count - 1)
                    }
                }
                .padding(.horizontal, 18)
                .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 16))

                BoundaryCallout(
                    title: "Live device actions remain off",
                    detail: "This desktop surface does not inspect, install on, launch, mirror, or configure the connected charging iPhone. Physical enrollment and APNs credential work remain separate, explicit live operations."
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.canvas)
    }
}

struct DesktopSettingsModal: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @ObservedObject var updates: DesktopUpdateViewModel
    @ObservedObject var automaticBackup: DesktopAutomaticBackupViewModel
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            DesktopSettingsView(
                model: model,
                integrations: integrations,
                updates: updates,
                automaticBackup: automaticBackup,
                dismiss: dismiss
            )
                .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(KanameColor.separator, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onTapGesture { }
                .padding(24)
                .accessibilityAddTraits(.isModal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand(perform: dismiss)
    }
}

struct DesktopSettingsView: View {
    @Environment(\.dismiss) private var environmentDismiss
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @ObservedObject var updates: DesktopUpdateViewModel
    @ObservedObject var automaticBackup: DesktopAutomaticBackupViewModel
    @State private var draft: DesktopPreferences
    private let explicitDismiss: (() -> Void)?

    init(
        model: DesktopAppModel,
        integrations: DesktopPersonalIntegrationViewModel,
        updates: DesktopUpdateViewModel,
        automaticBackup: DesktopAutomaticBackupViewModel,
        dismiss: (() -> Void)? = nil
    ) {
        self.model = model
        self.integrations = integrations
        self.updates = updates
        self.automaticBackup = automaticBackup
        explicitDismiss = dismiss
        _draft = State(initialValue: model.snapshot.preferences)
    }

    var body: some View {
        DesktopSettingsShell(
            model: model,
            integrations: integrations,
            updates: updates,
            automaticBackup: automaticBackup,
            draft: $draft,
            dismiss: { explicitDismiss?() ?? environmentDismiss() }
        )
        .onChange(of: draft) { updated in
            var persisted = updated
            if TimeZone(identifier: updated.defaultScheduleTimeZoneIdentifier) == nil {
                persisted.defaultScheduleTimeZoneIdentifier = model.snapshot.preferences.defaultScheduleTimeZoneIdentifier
            }
            model.updatePreferences(persisted)
        }
    }

}

private struct DesktopSettingsShell: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.desktopQALargeText) private var usesQALargeText
    private enum Category: String, CaseIterable, Identifiable {
        case general, commands, integrations, providers, updates, calendars, scheduling, privacy, backups, diagnostics
        private struct Presentation {
            let label: String
            let symbol: String
            let detail: String
        }
        var id: String { rawValue }
        private var presentation: Presentation {
            switch self {
            case .general: .init(label: "General", symbol: "gearshape.fill", detail: "Workspace presentation and review defaults")
            case .commands: .init(label: "Commands & Shortcuts", symbol: "command", detail: "Keyboard-first navigation and the Kaname Command Center")
            case .integrations: .init(label: "Integrations", symbol: "link", detail: "Personal services, account health, and explicit authorization")
            case .providers: .init(label: "Coding providers", symbol: "chevron.left.forwardslash.chevron.right", detail: "Local coding agents available to Kaname")
            case .updates: .init(label: "Updates", symbol: "arrow.triangle.2.circlepath.circle.fill", detail: "Verified switching, health checks, and rollback")
            case .calendars: .init(label: "Calendars", symbol: "calendar", detail: "Choose which connected calendars Kaname may show")
            case .scheduling: .init(label: "Scheduling", symbol: "clock.fill", detail: "Stable wall-clock behavior when you travel")
            case .privacy: .init(label: "Privacy & Safety", symbol: "lock.shield.fill", detail: "Notification content and execution authority")
            case .backups: .init(label: "Backup & Restore", symbol: "externaldrive.badge.icloud", detail: "Opt-in encrypted local, R2, or S3 recovery generations")
            case .diagnostics: .init(label: "Diagnostics", symbol: "lifepreserver.fill", detail: "Retention and privacy-safe support information")
            }
        }
        var label: String { presentation.label }
        var symbol: String { presentation.symbol }
        var detail: String { presentation.detail }
    }

    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @ObservedObject var updates: DesktopUpdateViewModel
    @ObservedObject var automaticBackup: DesktopAutomaticBackupViewModel
    @Binding var draft: DesktopPreferences
    let dismiss: () -> Void
    @State private var category: Category = .general
    @State private var settingsQuery = ""
    @State private var showsUpdateInstallConfirmation = false
    @StateObject private var recoveryActions = DesktopRecoveryViewModel()
    @FocusState private var focusedCategory: Category?

    init(
        model: DesktopAppModel,
        integrations: DesktopPersonalIntegrationViewModel,
        updates: DesktopUpdateViewModel,
        automaticBackup: DesktopAutomaticBackupViewModel,
        draft: Binding<DesktopPreferences>,
        dismiss: @escaping () -> Void
    ) {
        self.model = model
        self.integrations = integrations
        self.updates = updates
        self.automaticBackup = automaticBackup
        _draft = draft
        self.dismiss = dismiss
        let arguments = CommandLine.arguments
        let requested = arguments.firstIndex(of: "--desktop-settings-category")
            .flatMap { arguments.indices.contains($0 + 1) ? Category(rawValue: arguments[$0 + 1]) : nil }
        _category = State(initialValue: requested ?? .general)
    }

    var body: some View {
        HStack(spacing: 0) {
            categoryRail
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(category.label).font(.title2.weight(.bold))
                            Text(pageDetail).font(.subheadline).foregroundStyle(.secondary)
                        }
                        categoryPage
                        if let message = integrations.message {
                            Label(message, systemImage: "info.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(KanameColor.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                }
                Divider()
                footer
            }
        }
        .background(KanameColor.canvas)
        .frame(minWidth: 720, idealWidth: 940, maxWidth: 1_040, minHeight: 480, idealHeight: 640, maxHeight: 660)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kaname settings")
        .onAppear {
            DispatchQueue.main.async { focusedCategory = category }
            if category == .updates { updates.checkForUpdates(manual: false) }
        }
        .onChange(of: category) { selected in
            if selected == .updates { updates.checkForUpdates(manual: false) }
        }
        .onChange(of: settingsQuery) { _ in
            if !filteredCategories.contains(category), let first = filteredCategories.first {
                category = first
            }
        }
        .alert(
            updateInstallConfirmationTitle,
            isPresented: $showsUpdateInstallConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Install and relaunch") { updates.switchAndRelaunch(model: model) }
        } message: {
            Text("Kaname will checkpoint the current UI, install the verified staged build, and relaunch. An active approval or a workspace persistence error blocks the switch, and a failed health check automatically restores the previous app.")
        }
    }

    private var categoryRail: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Settings", systemImage: "gearshape.fill")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            TextField("Search settings", text: $settingsQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .accessibilityLabel("Search settings categories")
            ForEach(filteredCategories) { item in
                Button { category = item } label: {
                    Label(item.label, systemImage: item.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            category == item ? KanameColor.accent.opacity(0.22) : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(category == item ? KanameColor.textPrimary : .secondary)
                }
                .buttonStyle(.plain)
                .focused($focusedCategory, equals: item)
                .accessibilityAddTraits(category == item ? .isSelected : [])
            }
            Spacer()
            Button("Return to Kaname", systemImage: "arrow.left", action: dismiss)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(12)
        }
        .padding(.top, 18)
        .padding(.horizontal, 10)
        .frame(
            minWidth: usesAccessibilityTextLayout ? 230 : 180,
            idealWidth: usesAccessibilityTextLayout ? 260 : 205,
            maxWidth: usesAccessibilityTextLayout ? 290 : 230
        )
        .background(KanameColor.surface)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack { footerStatus; Spacer(); refreshStatusButton }
            VStack(alignment: .leading, spacing: 8) {
                footerStatus
                refreshStatusButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
    }

    private var updateInstallConfirmationTitle: String {
        let version = updates.receipt.version ?? "the staged update"
        let build = updates.receipt.build.map { " (\($0))" } ?? ""
        return "Install Kaname \(version)\(build)?"
    }

    private var footerStatus: some View {
        Label(
            TimeZone(identifier: draft.defaultScheduleTimeZoneIdentifier) == nil
                ? "The time zone will save when it is valid; other changes are saved."
                : "Changes save automatically.",
            systemImage: TimeZone(identifier: draft.defaultScheduleTimeZoneIdentifier) == nil
                ? "exclamationmark.triangle.fill"
                : "checkmark.circle.fill"
        )
        .font(.caption)
        .foregroundStyle(
            TimeZone(identifier: draft.defaultScheduleTimeZoneIdentifier) == nil
                ? KanameColor.warning
                : Color.secondary.opacity(0.65)
        )
    }

    private var refreshStatusButton: some View {
        Button("Refresh all status", systemImage: "arrow.clockwise") {
            integrations.refreshAllStatus(model: model)
        }
    }

    private var usesAccessibilityTextLayout: Bool {
        usesQALargeText || dynamicTypeSize.isAccessibilitySize
    }

    private var filteredCategories: [Category] {
        let query = settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return Category.allCases }
        return Category.allCases.filter {
            $0.label.lowercased().contains(query)
                || $0.detail.lowercased().contains(query)
        }
    }

    private var pageDetail: String {
        category.detail
    }

    @ViewBuilder private var categoryPage: some View {
        switch category {
        case .general: generalPage
        case .commands: commandsPage
        case .integrations: integrationsPage
        case .providers: providersPage
        case .updates: updatesPage
        case .calendars: calendarsPage
        case .scheduling: schedulingPage
        case .privacy: privacyPage
        case .backups: DesktopAutomaticBackupSettings(model: model, backup: automaticBackup)
        case .diagnostics: diagnosticsPage
        }
    }

    @AppStorage("kaname.appearance") private var appearance = "dark"

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "Appearance", symbol: "circle.lefthalf.filled") {
                Picker("Appearance", selection: $appearance) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("Match system").tag("system")
                }
                .pickerStyle(.segmented)
            }
            SettingsSection(title: "Workspace", symbol: "macwindow") {
                Toggle("Show technical details by default", isOn: $draft.showTechnicalDetails)
                Toggle("Use compact thread rows", isOn: $draft.compactRows)
                Toggle("Confirm before archiving", isOn: $draft.confirmBeforeArchiving)
            }
        }
    }

    private var commandsPage: some View {
        SettingsSection(title: "Commands & shortcuts", symbol: "command") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("Create and find").font(.subheadline.weight(.semibold))
                    Color.clear.frame(height: 1)
                }
                LabeledContent("Command Center", value: "⌘K")
                LabeledContent("New conversation draft", value: "⌘N")
                LabeledContent("Focus current composer", value: "⌘L")
                GridRow {
                    Text("Navigate and steer").font(.subheadline.weight(.semibold))
                    Color.clear.frame(height: 1)
                }
                LabeledContent("Home / Threads / Inbox / Projects", value: "⌘1 / ⌘2 / ⌘3 / ⌘4")
                LabeledContent("Back", value: "⌘[")
                LabeledContent("Toggle inspector", value: "⌘⌥I")
                LabeledContent("Interrupt current run", value: "⌘.")
                LabeledContent("Retry current turn", value: "⌘⇧R")
                GridRow {
                    Text("Contextual behavior").font(.subheadline.weight(.semibold))
                    Color.clear.frame(height: 1)
                }
                Text("Type > in the Command Center to find local actions. Plain text searches saved conversations, projects, domains, approvals, and artifacts without contacting a provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .gridCellColumns(2)
                Text("The default new-conversation path uses the selected project's kind, provider, model, and safe authority. Choose Configure new conversation from the toolbar menu or Command Center when you need to override them before opening the draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .gridCellColumns(2)
            }
        }
    }

    private var integrationsPage: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Connection state refreshes automatically every 15 minutes.", systemImage: "clock.arrow.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let checkedAt = integrations.lastIntegrationRefreshAt {
                    Text(checkedAt, style: .relative).font(.caption).foregroundStyle(.tertiary)
                }
            }
            SettingsIntegrationCard(
                title: "Google",
                detail: googleDetail,
                symbol: "g.circle.fill",
                tint: .blue,
                connected: !integrations.googleAccounts.isEmpty,
                busy: integrations.isRefreshingGoogle || integrations.isConnectingGoogle
            ) {
                if integrations.googleAccountLoadFailure != nil,
                   integrations.googleAccounts.isEmpty {
                    Button("Retry saved accounts", systemImage: "arrow.clockwise") {
                        integrations.retrySavedGoogleAccounts(model: model)
                    }
                } else {
                    Button(
                        integrations.googleAccounts.isEmpty ? "Connect Google" : "Add account",
                        systemImage: "person.badge.plus"
                    ) {
                        integrations.connectGoogleAccount(model: model)
                    }
                    .disabled(!integrations.hasGoogleClientConfiguration)
                }
                if !integrations.googleAccounts.isEmpty {
                    Button("Refresh", systemImage: "arrow.clockwise") { integrations.refreshGoogle(model: model) }
                }
            } details: {
                if let loadFailure = integrations.googleAccountLoadFailure,
                   integrations.googleAccounts.isEmpty {
                    Text(loadFailure)
                        .font(.caption).foregroundStyle(.secondary)
                } else if integrations.googleAccounts.isEmpty {
                    Text(integrations.hasGoogleClientConfiguration
                        ? "Connect Google opens the system browser, asks for Gmail read/manage/compose plus Calendar list and event access, and returns directly to Kaname. Existing Google accounts must reconnect once before newer mail or approved Calendar changes can run."
                        : "Google is not registered in this build yet. Its private OAuth client registration belongs in Kaname's build configuration, not in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(integrations.googleAccounts) { account in
                        HStack {
                            Circle().fill(KanameColor.success).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName).font(.subheadline.weight(.semibold))
                                Text(account.identity).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Disconnect") { integrations.disconnectGoogleAccount(id: account.id, model: model) }
                                .buttonStyle(.borderless).foregroundStyle(KanameColor.danger)
                        }
                    }
                }
            }
            SettingsIntegrationCard(
                title: "Apple Calendar",
                detail: "Permission: \(appleAccessLabel)",
                symbol: "calendar.circle.fill",
                tint: .red,
                connected: integrations.appleAccessState == .ready,
                busy: integrations.isRequestingAppleCalendar
            ) {
                Button(integrations.appleAccessState == .notRequested ? "Request access" : "Refresh") {
                    if integrations.appleAccessState == .notRequested {
                        integrations.requestAppleCalendarAccess(model: model)
                    } else {
                        integrations.refreshAppleCalendarStatus(model: model)
                    }
                }
            } details: {
                Text("Uses macOS EventKit and the calendar accounts already configured on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsIntegrationCard(
                title: "GitHub",
                detail: integrations.githubAccess.map { "Connected as @\($0.login)" } ?? "Uses your current gh CLI session",
                symbol: "point.3.connected.trianglepath.dotted",
                tint: .purple,
                connected: integrations.githubAccess != nil,
                busy: integrations.isRefreshingGitHub
            ) {
                Button("Refresh gh access", systemImage: "arrow.clockwise") { integrations.refreshGitHub(model: model) }
            } details: {
                Text("Kaname asks gh for the current host and account; it never copies the gh token.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var providersPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Each adapter uses its installed CLI and existing sign-in.").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("Cached immediately · refreshes every 5 minutes")
                        if let checkedAt = integrations.lastProviderRefreshAt {
                            Text("·")
                            Text(checkedAt, style: .relative)
                        }
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if integrations.isRefreshingProviders { ProgressView().controlSize(.small) }
                Button("Refresh now", systemImage: "arrow.clockwise") { integrations.refreshProviders() }
                    .disabled(integrations.isRefreshingProviders)
            }
            ForEach(providerDescriptors) { provider in
                SettingsProviderRow(
                    provider: provider,
                    snapshot: integrations.providerCapabilities.first { $0.instance.driver == provider.driver }
                )
            }
        }
    }

    private var calendarsPage: some View {
        SettingsSection(title: "Visible in Kaname", symbol: "calendar.badge.checkmark") {
            Text("These choices affect Kaname only; they never hide or delete calendars at the provider.")
                .font(.caption).foregroundStyle(.secondary)
            if model.snapshot.domains.calendarSources.isEmpty {
                Label("Connect Google or Apple Calendar from Integrations first.", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.domains.calendarSources) { source in
                Toggle(isOn: Binding(
                    get: { source.isEnabled },
                    set: { model.setCalendarSourceEnabled(id: source.id, enabled: $0) }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName)
                            Text("\(source.provider.label) · \(source.ownerIdentity)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: source.provider == .google ? "g.circle.fill" : "apple.logo")
                            .foregroundStyle(source.provider == .google ? .blue : .red)
                    }
                }
            }
        }
    }

    private var updatesPage: some View {
        VStack(spacing: 14) {
            SettingsSection(title: "Update availability", symbol: "arrow.down.circle.fill") {
                LabeledContent("Installed", value: updates.currentVersionLabel)
                LabeledContent("Discovery", value: updates.discoveryStatus.rawValue.capitalized)
                if updates.environment.channel == .stable {
                    Toggle("Check the private local catalog automatically", isOn: Binding(
                        get: { updates.discoveryPreferences.automaticChecksEnabled },
                        set: { updates.setAutomaticChecksEnabled($0) }
                    ))
                    Text("Automatic checks run 15 seconds after launch and every four minutes while stable Kaname remains open. Activation and opening Updates check when the four-minute interval has elapsed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let checkedAt = updates.discoveryPreferences.lastSuccessAtUnixMillis {
                        LabeledContent(
                            "Last successful check",
                            value: Date(timeIntervalSince1970: Double(checkedAt) / 1_000).formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    HStack {
                        Button("Check now", systemImage: "arrow.clockwise") { updates.checkForUpdates(manual: true) }
                            .disabled(updates.isChecking || updates.isBusy)
                        if updates.discoveryStatus == .deferred {
                            Button("Review now", systemImage: "eye") { updates.reviewAvailableUpdate() }
                        }
                        if updates.discoveryStatus == .skipped {
                            Button("Unskip", systemImage: "arrow.uturn.backward") { updates.unskipAvailableUpdate() }
                        }
                    }
                    if let update = updates.availableUpdate,
                       updates.discoveryStatus != .deferred,
                       updates.discoveryStatus != .skipped {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Kaname \(update.version) (\(update.build))", systemImage: "shippingbox.fill")
                                .font(.headline)
                            LabeledContent("Source", value: update.sourceLabel)
                            LabeledContent("Published", value: Date(timeIntervalSince1970: Double(update.publishedAtUnixMillis) / 1_000).formatted(date: .abbreviated, time: .shortened))
                            Text(update.releaseNotes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack {
                                Button("Download update", systemImage: "arrow.down.circle") {
                                    updates.verifyAndStageAvailable()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(updates.isBusy || updates.discoveryStatus == .skipped)
                                Button("Remind me in 24 hours", systemImage: "clock") { updates.deferAvailableUpdate() }
                                    .disabled(updates.isBusy)
                            }
                            Button("Skip this exact build", systemImage: "forward.end") { updates.skipAvailableUpdate() }
                                .disabled(updates.isBusy)
                        }
                        .padding(12)
                        .background(KanameColor.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    Label("Candidate never reads, publishes, or stages the stable update catalog.", systemImage: "testtube.2")
                        .font(.caption)
                        .foregroundStyle(KanameColor.accent)
                }
            }
            SettingsSection(title: "Update continuity", symbol: "arrow.triangle.2.circlepath.circle.fill") {
                LabeledContent("Channel", value: updates.environment.displayName)
                LabeledContent("State", value: updates.receipt.status.rawValue.capitalized)
                if let version = updates.receipt.version {
                    LabeledContent("Ready", value: "\(version) (\(updates.receipt.build ?? "—"))")
                }
                Text(updates.receipt.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(
                    "Verification is same-signer, forward-only, and digest-bound.",
                    systemImage: "checkmark.seal"
                )
                .font(.caption)
                .foregroundStyle(KanameColor.accent)
                if let releaseNotes = updates.receipt.releaseNotes,
                   !releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DisclosureGroup("Release notes") {
                        Text(releaseNotes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(10)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }
                if updates.environment.channel == .stable {
                    Grid(horizontalSpacing: 8) {
                        GridRow {
                            Button("Choose update manually…", systemImage: "folder") { updates.chooseAndStage() }
                                .disabled(updates.isBusy)
                            Button("Install and relaunch", systemImage: "arrow.clockwise") {
                                showsUpdateInstallConfirmation = true
                            }
                            .disabled(updates.isBusy || updates.receipt.status != .staged)
                            Button("Rollback", systemImage: "arrow.uturn.backward") { updates.rollback(model: model) }
                                .disabled(updates.isBusy || !updates.canRollback)
                        }
                    }
                } else {
                    Label("Candidate state is isolated. Qualify here, then stage a stable-identity build from stable Kaname.", systemImage: "testtube.2")
                        .font(.caption)
                        .foregroundStyle(KanameColor.accent)
                }
                if let message = updates.message {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SettingsSection(title: "Switch safety", symbol: "checkmark.shield.fill") {
                Label("Composer drafts and the current selection are checkpointed locally before a switch.", systemImage: "square.and.arrow.down")
                Label("An active approval blocks switching until you resolve it.", systemImage: "hand.raised.fill")
                Label("A missed health deadline automatically restores the previous bundle.", systemImage: "lifepreserver.fill")
            }
        }
    }

    private var schedulingPage: some View {
        SettingsSection(title: "Default schedule zone", symbol: "clock.badge.checkmark") {
            TextField("IANA time zone", text: $draft.defaultScheduleTimeZoneIdentifier)
            HStack {
                Button("Use current zone") { draft.defaultScheduleTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier }
                Spacer()
                Text("Viewer: \(TimeZone.autoupdatingCurrent.identifier)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Recurring schedules stay pinned to this zone's wall clock. Kaname also shows the equivalent in your current viewing zone.")
                .font(.caption).foregroundStyle(.secondary)
            if TimeZone(identifier: draft.defaultScheduleTimeZoneIdentifier) == nil {
                Label("Enter a valid IANA identifier such as Asia/Tokyo.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(KanameColor.warning)
            }
        }
    }

    private var privacyPage: some View {
        VStack(spacing: 14) {
            SettingsSection(title: "Notification privacy", symbol: "hand.raised.fill") {
                Picker("Preview content", selection: $draft.previewPrivacy) {
                    ForEach(DesktopPreferences.PreviewPrivacy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Safe summary never includes private task content. Hidden is the default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection(title: "Execution authority", symbol: "lock.shield.fill") {
                Toggle("Safe mode (disable future write integrations)", isOn: $draft.safeMode)
                LabeledContent("Default", value: "Local-only draft")
                LabeledContent("Provider writes", value: "Exact approval required")
                LabeledContent("External accounts", value: readyAccountSummary)
            }
        }
    }

    private var diagnosticsPage: some View {
        SettingsSection(title: "Recovery & diagnostics", symbol: "lifepreserver.fill") {
            Stepper("Keep audit metadata for \(draft.auditRetentionDays) days", value: $draft.auditRetentionDays, in: 7...365, step: 7)
            HStack {
                Button("Inspect diagnostics…", systemImage: "doc.text.magnifyingglass") {
                    NotificationCenter.default.post(name: .kanamePresentDiagnostics, object: nil)
                }
                Button("Export verified backup…", systemImage: "externaldrive.badge.plus") {
                    recoveryActions.exportBackup(model: model)
                }
            }
            if let message = recoveryActions.message {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Diagnostics are inspect-before-copy/export and include counts and health only. They exclude content, identities, paths, and credentials. Backups and crash information are never uploaded automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Factory reset is available only from the read-only Recovery Center and only after a backup validates successfully.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var providerDescriptors: [SettingsProviderDescriptor] {
        [
            .init(name: "Codex", driver: .codex, symbol: "terminal.fill", tint: KanameColor.accent, detail: "OpenAI coding sessions, models, and skills"),
            .init(name: "Claude", driver: .claudeAgent, symbol: "sparkles", tint: .orange, detail: "Claude Code sessions and models"),
            .init(name: "OpenCode", driver: .openCode, symbol: "chevron.left.forwardslash.chevron.right", tint: .purple, detail: "OpenCode sessions and upstream providers"),
            .init(name: "Cursor", driver: .cursorAgent, symbol: "cursorarrow.rays", tint: KanameColor.active, detail: "Cursor CLI print + stream-json conversation sessions"),
            .init(name: "Grok", driver: .grokBuild, symbol: "bolt.fill", tint: KanameColor.warning, detail: "Grok Build headless --single conversation sessions"),
        ]
    }

    private var googleDetail: String {
        let count = integrations.googleAccounts.count
        let calendars = model.snapshot.domains.calendarSources.filter { $0.provider == .google }.count
        if count == 0 { return integrations.hasGoogleClientConfiguration ? "Ready to add an account" : "Unavailable in this build" }
        return "\(count) account\(count == 1 ? "" : "s") · \(calendars) calendar\(calendars == 1 ? "" : "s")"
    }

    private var readyAccountSummary: String {
        let count = model.snapshot.domains.accounts.filter { $0.status == .ready }.count
        return count == 0 ? "Not connected" : "\(count) ready"
    }

    private var appleAccessLabel: String {
        switch integrations.appleAccessState {
        case .notRequested: "Not requested"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .writeOnly: "Write only"
        case .ready: "Ready"
        case .unavailable: "Unavailable"
        }
    }

}

private struct SettingsProviderDescriptor: Identifiable {
    let name: String
    let driver: ProviderDriverKind
    let symbol: String
    let tint: Color
    let detail: String
    var id: String { driver.rawValue }
}

private struct SettingsProviderRow: View {
    let provider: SettingsProviderDescriptor
    let snapshot: ProviderCapabilitySnapshot?

    private var connected: Bool { snapshot?.state == .ready }
    private var needsAttention: Bool {
        snapshot?.state == .authenticationRequired || snapshot?.state == .degraded
    }
    private var summary: String {
        guard let snapshot else { return "Not checked" }
        let version = snapshot.version.map { "v\($0) · " } ?? ""
        switch snapshot.state {
        case .ready: return "\(version)Authenticated"
        case .degraded: return "\(version)Available with limited capabilities"
        case .authenticationRequired: return "\(version)Sign in with the provider CLI"
        case .unavailable: return "Executable not found"
        case .unsupported: return "Installed version is unsupported"
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(provider.detail).font(.caption).foregroundStyle(.secondary)
                if let snapshot {
                    LabeledContent("Authentication", value: snapshot.authentication.rawValue.capitalized)
                    LabeledContent("Models", value: snapshot.models.isEmpty ? "Reported on first session" : "\(snapshot.models.count) available")
                    LabeledContent("Skills", value: snapshot.skills.isEmpty ? "None reported" : "\(snapshot.skills.count) available")
                    if let detail = snapshot.detail { Text(detail).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(provider.tint.opacity(0.18)).frame(width: 38, height: 38)
                    Image(systemName: provider.symbol).foregroundStyle(provider.tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(connected ? KanameColor.success : needsAttention ? KanameColor.warning : .secondary).frame(width: 8, height: 8)
            }
        }
        .panelStyle()
    }
}

private struct SettingsIntegrationCard<Actions: View, Details: View>: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let connected: Bool
    let busy: Bool
    let actions: Actions
    let details: Details

    init(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        connected: Bool,
        busy: Bool,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder details: () -> Details
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
        self.connected = connected
        self.busy = busy
        self.actions = actions()
        self.details = details()
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) { details }.padding(.top, 10)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.18)).frame(width: 42, height: 42)
                    Image(systemName: symbol).font(.title3).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(connected ? KanameColor.success : .secondary).frame(width: 7, height: 7)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                HStack(spacing: 7) { actions }.buttonStyle(.bordered).disabled(busy)
            }
        }
        .panelStyle()
    }
}
