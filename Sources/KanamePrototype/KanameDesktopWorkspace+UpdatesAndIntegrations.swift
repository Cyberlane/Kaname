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

struct DesktopUpdateNotificationCard: View {
    let notice: KanameUpdateNotice
    let releaseNotes: String?
    let failureMessage: String?
    let primaryAction: () -> Void
    let dismiss: (() -> Void)?

    private var title: String {
        switch notice.phase {
        case .available: "Update available"
        case .retry: "Retry update"
        case .preparing: "Preparing update…"
        case .readyToInstall: "Restart to update"
        }
    }

    private var symbol: String {
        switch notice.phase {
        case .available, .retry: "arrow.down.circle.fill"
        case .preparing: "arrow.triangle.2.circlepath"
        case .readyToInstall: "arrow.clockwise.circle.fill"
        }
    }

    private var helpText: String {
        var parts = ["Kaname \(notice.version) (\(notice.build))."]
        if let failureMessage, !failureMessage.isEmpty {
            parts.append(failureMessage)
        } else if let releaseNotes, !releaseNotes.isEmpty {
            parts.append(String(releaseNotes.prefix(600)))
        }
        return parts.joined(separator: " ")
    }

    private var accessibilityAction: String {
        switch notice.phase {
        case .available: "Download update."
        case .retry: "Retry preparing update."
        case .preparing: "Verification and private staging are in progress."
        case .readyToInstall: "Install and relaunch."
        }
    }

    var body: some View {
        KanameSurface(padding: KanameSpacing.small, background: KanameColor.raised) {
            HStack(spacing: KanameSpacing.xSmall) {
                Button(action: primaryAction) {
                    HStack(spacing: KanameSpacing.small) {
                        if notice.phase == .preparing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: symbol)
                                .frame(width: 16)
                        }
                        (
                            Text(title).font(.caption.weight(.semibold))
                                + Text("\nKaname \(notice.version) (\(notice.build))")
                                    .font(.caption2)
                                    .foregroundColor(KanameColor.textSecondary)
                        )
                        .lineLimit(2)
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(notice.phase == .preparing)
                .help(helpText)
                .accessibilityLabel("Kaname \(notice.version) build \(notice.build). \(accessibilityAction)")

                if let dismiss {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss until next launch")
                    .accessibilityLabel("Dismiss update until next launch")
                }
            }
        }
        .foregroundStyle(KanameColor.textPrimary)
    }
}

@MainActor
final class DesktopUpdateViewModel: ObservableObject {
    let environment: KanameDesktopEnvironment
    @Published private(set) var receipt: KanameUpdateReceipt
    @Published private(set) var discoveryStatus: KanameUpdateDiscoveryStatus = .notChecked
    @Published private(set) var availableUpdate: KanameAvailableUpdate?
    @Published private(set) var discoveryPreferences = KanameUpdateDiscoveryPreferences()
    @Published private(set) var isBusy = false
    @Published private(set) var isChecking = false
    @Published private(set) var canRollback = false
    @Published private(set) var message: String?

    private let coordinator: KanameUpdateCoordinator
    private let catalog: KanameLocalDogfoodUpdateCatalog
    private let preferenceStore: KanameUpdateDiscoveryPreferencesStore
    private var helperProcess: Process?
    private var automaticCheckTask: _Concurrency.Task<Void, Never>?
    private var hasLoadedDiscoveryPreferences = false
    private var workspaceIsReady = false
    private static let deferIntervalMillis: Int64 = 24 * 60 * 60 * 1_000

    init(environment: KanameDesktopEnvironment = .current) {
        self.environment = environment
        coordinator = KanameUpdateCoordinator(environment: environment)
        catalog = KanameLocalDogfoodUpdateCatalog(environment: environment)
        preferenceStore = KanameUpdateDiscoveryPreferencesStore(environment: environment)
        receipt = KanameUpdateReceipt(
            status: .idle,
            detail: environment.channel == .stable
                ? "No update is staged."
                : "This candidate has its own state and cannot replace stable Kaname.",
            updatedAtUnixMillis: 0
        )
        _Concurrency.Task { await refresh() }
    }

    deinit {
        automaticCheckTask?.cancel()
    }

    var currentVersionLabel: String {
        let versionValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        let buildValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
        let version = (versionValue as? String) ?? "Unknown"
        let build = (buildValue as? String) ?? "—"
        return "\(version) (\(build))"
    }

    var sidebarNotice: KanameUpdateNotice? {
        KanameUpdateNoticeProjection.notice(
            channel: environment.channel,
            discoveryStatus: discoveryStatus,
            availableUpdate: availableUpdate,
            receipt: receipt
        )
    }

    func startAutomaticChecks() {
        workspaceIsReady = true
        beginAutomaticChecksIfReady()
    }

    func checkForUpdates(manual: Bool) {
        checkForUpdates(manual: manual, ignoresAutomaticInterval: false)
    }

    private func checkForUpdates(manual: Bool, ignoresAutomaticInterval: Bool) {
        guard environment.channel == .stable, !isChecking, !isBusy else { return }
        guard receipt.status != .staged, receipt.status != .switching else { return }
        guard manual || hasLoadedDiscoveryPreferences else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        if !manual {
            guard discoveryPreferences.automaticChecksEnabled else { return }
            if !ignoresAutomaticInterval,
               !KanameUpdateAutomaticCheckPolicy.permitsCheck(
                   lastAttemptAtUnixMillis: discoveryPreferences.lastAttemptAtUnixMillis,
                   nowUnixMillis: now
               ) {
                return
            }
        }
        isChecking = true
        discoveryStatus = .checking
        message = manual ? "Checking the private local dogfood catalog…" : nil
        _Concurrency.Task {
            var preferences = await preferenceStore.load()
            preferences.lastAttemptAtUnixMillis = now
            preferences.lastSourceIdentifier = KanameLocalDogfoodUpdateCatalog.sourceIdentifier
            do {
                let update = try await catalog.latestUpdate()
                preferences.lastSuccessAtUnixMillis = now
                availableUpdate = update
                if let update, preferences.skippedIdentity == update.identity {
                    discoveryStatus = .skipped
                    message = "Build \(update.build) is skipped on this Mac."
                } else if let update,
                          !manual,
                          preferences.deferredIdentity == update.identity,
                          (preferences.deferredUntilUnixMillis ?? 0) > now {
                    discoveryStatus = .deferred
                    message = "Build \(update.build) is deferred for 24 hours."
                } else if let update {
                    discoveryStatus = .available
                    message = "Kaname \(update.version) (\(update.build)) is available from \(update.sourceLabel)."
                } else {
                    discoveryStatus = .upToDate
                    message = manual ? "This Kaname build is up to date." : nil
                }
                try await preferenceStore.save(preferences)
            } catch {
                discoveryStatus = .failed
                message = error.localizedDescription
                try? await preferenceStore.save(preferences)
            }
            discoveryPreferences = preferences
            isChecking = false
        }
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        var preferences = discoveryPreferences
        preferences.automaticChecksEnabled = enabled
        discoveryPreferences = preferences
        _Concurrency.Task { try? await preferenceStore.save(preferences) }
        if enabled {
            checkForUpdates(manual: false, ignoresAutomaticInterval: true)
        }
    }

    func deferAvailableUpdate() {
        guard let update = availableUpdate else { return }
        var preferences = discoveryPreferences
        preferences.deferredIdentity = update.identity
        preferences.deferredUntilUnixMillis = Int64(Date().timeIntervalSince1970 * 1_000) + Self.deferIntervalMillis
        discoveryPreferences = preferences
        discoveryStatus = .deferred
        message = "Build \(update.build) is deferred for 24 hours."
        _Concurrency.Task { try? await preferenceStore.save(preferences) }
    }

    func reviewAvailableUpdate() {
        var preferences = discoveryPreferences
        preferences.deferredIdentity = nil
        preferences.deferredUntilUnixMillis = nil
        applyAvailableState(preferences)
    }

    func skipAvailableUpdate() {
        guard let update = availableUpdate else { return }
        var preferences = discoveryPreferences
        preferences.skippedIdentity = update.identity
        preferences.deferredIdentity = nil
        preferences.deferredUntilUnixMillis = nil
        discoveryPreferences = preferences
        discoveryStatus = .skipped
        message = "Build \(update.build) is skipped on this Mac."
        _Concurrency.Task { try? await preferenceStore.save(preferences) }
    }

    func unskipAvailableUpdate() {
        var preferences = discoveryPreferences
        preferences.skippedIdentity = nil
        applyAvailableState(preferences)
    }

    private func applyAvailableState(_ preferences: KanameUpdateDiscoveryPreferences) {
        discoveryPreferences = preferences
        discoveryStatus = availableUpdate == nil ? .upToDate : .available
        message = availableUpdate.map { "Kaname \($0.version) (\($0.build)) is available from \($0.sourceLabel)." }
        _Concurrency.Task { try? await preferenceStore.save(preferences) }
    }

    func verifyAndStageAvailable() {
        guard let update = availableUpdate, !isBusy else { return }
        isBusy = true
        discoveryStatus = .verifying
        message = "Rechecking the digest and same-signer trust before staging…"
        _Concurrency.Task {
            do {
                let artifactURL = try await catalog.verifiedArtifactURL(for: update)
                receipt = try await coordinator.stage(bundleURL: artifactURL)
                discoveryStatus = .staged
                message = "Update downloaded and verified. Your current Kaname remains active until you choose Install and relaunch."
            } catch {
                discoveryStatus = .failed
                message = error.localizedDescription
            }
            isBusy = false
            await refreshRollbackAvailability()
        }
    }

    func chooseAndStage() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose a stable Kaname update"
        panel.prompt = "Verify and stage"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        message = "Verifying the signature and staging a private copy…"
        _Concurrency.Task {
            do {
                receipt = try await coordinator.stage(bundleURL: url)
                message = "Update ready. Your current Kaname remains active until you choose Switch and relaunch."
            } catch {
                message = error.localizedDescription
            }
            isBusy = false
            await refreshRollbackAvailability()
        }
#endif
    }

    func switchAndRelaunch(model: DesktopAppModel) {
#if os(macOS)
        beginRelaunch(model: model, operation: .installUpdate)
#endif
    }

    func rollback(model: DesktopAppModel) {
#if os(macOS)
        guard !isBusy else { return }
        beginRelaunch(model: model, operation: .rollback)
#endif
    }

#if os(macOS)
    private enum RelaunchOperation {
        case installUpdate
        case rollback

        var completionMessage: String {
            switch self {
            case .installUpdate:
                "Switching after the current UI closes…"
            case .rollback:
                "Restoring the previous Kaname UI…"
            }
        }
    }

    private func beginRelaunch(model: DesktopAppModel, operation: RelaunchOperation) {
        let hasActiveApproval = model.snapshot.operations.approvals.contains { $0.state == .awaitingApproval }
        let composerCheckpointed = model.flushComposerDrafts() && model.persistenceError == nil
        isBusy = true
        _Concurrency.Task {
            do {
                let request: KanameUpdateLaunchRequest
                switch operation {
                case .installUpdate:
                    request = try await coordinator.switchRequest(
                        installedBundleURL: Bundle.main.bundleURL,
                        processIdentifier: ProcessInfo.processInfo.processIdentifier,
                        composerCheckpointed: composerCheckpointed,
                        hasActiveApproval: hasActiveApproval
                    )
                case .rollback:
                    request = try await coordinator.rollbackRequest(
                        installedBundleURL: Bundle.main.bundleURL,
                        processIdentifier: ProcessInfo.processInfo.processIdentifier,
                        composerCheckpointed: composerCheckpointed,
                        hasActiveApproval: hasActiveApproval
                    )
                }
                try launchHelper(request)
                message = operation.completionMessage
                NSApplication.shared.terminate(nil)
            } catch {
                message = error.localizedDescription
                isBusy = false
            }
        }
    }
#endif

    private func launchHelper(_ request: KanameUpdateLaunchRequest) throws {
        let process = Process()
        process.executableURL = request.helperURL
        process.arguments = request.arguments
        try process.run()
        helperProcess = process
    }

    private func refresh() async {
        receipt = await coordinator.receipt()
        discoveryPreferences = await preferenceStore.load()
        hasLoadedDiscoveryPreferences = true
        await refreshRollbackAvailability()
        beginAutomaticChecksIfReady()
    }

    private func beginAutomaticChecksIfReady() {
        guard environment.channel == .stable,
              workspaceIsReady,
              hasLoadedDiscoveryPreferences,
              automaticCheckTask == nil else { return }
        automaticCheckTask = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(
                for: .seconds(KanameUpdateAutomaticCheckPolicy.startupDelaySeconds)
            )
            guard !_Concurrency.Task.isCancelled else { return }
            self?.checkForUpdates(manual: false, ignoresAutomaticInterval: true)
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(
                    for: .seconds(KanameUpdateAutomaticCheckPolicy.intervalSeconds)
                )
                guard !_Concurrency.Task.isCancelled else { return }
                self?.checkForUpdates(manual: false, ignoresAutomaticInterval: false)
            }
        }
    }

    private func refreshRollbackAvailability() async {
        let backupURL = await coordinator.backupBundleURL
        canRollback = FileManager.default.fileExists(atPath: backupURL.path)
    }
}

@MainActor
final class DesktopPersonalIntegrationViewModel: ObservableObject {
    @Published private(set) var googleAccounts: [NativeGoogleAccountSnapshot] = []
    @Published private(set) var googleCalendars: [PersonalCalendarSourceSnapshot] = []
    @Published private(set) var mailThreads: [PersonalMailThreadSnapshot] = []
    @Published private(set) var githubAccess: GitHubCLIAccessSnapshot?
    @Published private(set) var providerCapabilities: [ProviderCapabilitySnapshot] = []
    @Published private(set) var appleAccessState: AppleCalendarAccessState
    @Published private(set) var isRefreshingGoogle = false
    @Published private(set) var isConnectingGoogle = false
    @Published private(set) var hasGoogleClientConfiguration = false
    @Published private(set) var isRefreshingInbox = false
    @Published private(set) var isRefreshingGitHub = false
    @Published private(set) var isRefreshingProviders = false
    @Published private(set) var isRequestingAppleCalendar = false
    @Published private(set) var lastProviderRefreshAt: Date?
    @Published private(set) var lastIntegrationRefreshAt: Date?
    @Published private(set) var googleAccountLoadFailure: String?
    @Published private(set) var message: String?

    private let integrations = PersonalIntegrationService()
    private let googleIntegration: NativeGoogleIntegrationService
    private let appleCalendar = AppleCalendarIntegrationService()
    private let providerCache: ProviderCapabilityCacheStore
    init(environment: KanameDesktopEnvironment = .current) {
        googleIntegration = NativeGoogleIntegrationService(
            rootDirectory: environment.googleDirectory,
            keychainService: environment.googleKeychainService,
            accessMode: environment.googleIntegrationAccessMode
        )
        providerCache = ProviderCapabilityCacheStore(directory: environment.connectivityDirectory)
        appleAccessState = appleCalendar.accessState
        do {
            googleAccounts = try NativeGoogleIntegrationService.savedAccounts(
                rootDirectory: environment.googleDirectory
            )
            googleAccountLoadFailure = nil
        } catch {
            googleAccountLoadFailure = Self.savedGoogleAccountLoadFailure(error)
        }
        _Concurrency.Task {
            hasGoogleClientConfiguration = await googleIntegration.hasClientConfiguration
            if let cached = try? await providerCache.load() {
                providerCapabilities = cached.capabilities
                lastProviderRefreshAt = cached.checkedAt
            }
        }
    }

    private var monitoringTask: _Concurrency.Task<Void, Never>?

    func startMonitoring(model: DesktopAppModel) {
        guard monitoringTask == nil else { return }
        monitoringTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            hasGoogleClientConfiguration = await googleIntegration.hasClientConfiguration
            await reloadSavedGoogleAccounts(announce: false)
            if let cached = try? await providerCache.load() {
                providerCapabilities = cached.capabilities
                lastProviderRefreshAt = cached.checkedAt
            }
            guard !CommandLine.arguments.contains("--snapshot") else { return }

            refreshProviders(announce: false)
            refreshGitHub(model: model, announce: false)
            if !googleAccounts.isEmpty { refreshGoogle(model: model, announce: false) }
            refreshAppleCalendarStatus(model: model, announce: false)

            var cycle = 0
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .seconds(300))
                guard !_Concurrency.Task.isCancelled else { return }
                cycle += 1
                refreshProviders(announce: false)
                if cycle.isMultiple(of: 3) {
                    refreshGitHub(model: model, announce: false)
                    if !googleAccounts.isEmpty { refreshGoogle(model: model, announce: false) }
                    refreshAppleCalendarStatus(model: model, announce: false)
                }
            }
        }
    }

    func retrySavedGoogleAccounts(model: DesktopAppModel) {
        _Concurrency.Task {
            await reloadSavedGoogleAccounts(announce: true)
            guard !googleAccounts.isEmpty else { return }
            refreshGoogle(model: model)
        }
    }

    func refreshAllStatus(model: DesktopAppModel) {
        refreshProviders()
        refreshGitHub(model: model)
        if !googleAccounts.isEmpty { refreshGoogle(model: model) }
        refreshAppleCalendarStatus(model: model)
    }

    func refreshGoogle(model: DesktopAppModel, announce: Bool = true) {
        guard !isRefreshingGoogle else { return }
        isRefreshingGoogle = true
        if announce { message = nil }
        _Concurrency.Task {
            do {
                let discovered = try await googleIntegration.accounts()
                googleAccounts = discovered
                googleAccountLoadFailure = nil
                let gmailAccounts = discovered.map { accountRecord(for: $0, service: .gmail) }
                let calendarAccounts = discovered.map { accountRecord(for: $0, service: .googleCalendar) }
                model.replaceAccounts(
                    for: [.gmail, .googleCalendar],
                    with: gmailAccounts + calendarAccounts
                )

                var refreshedCalendars: [PersonalCalendarSourceSnapshot] = []
                var failedAccounts: [String] = []
                for account in discovered {
                    do {
                        refreshedCalendars.append(contentsOf: try await googleIntegration.listCalendars(
                            accountIDs: [account.id],
                            allowKeychainInteraction: announce
                        ))
                    } catch {
                        failedAccounts.append(account.identity)
                    }
                }
                googleCalendars = refreshedCalendars
                let googleSources = googleCalendars.map { calendar in
                    DesktopCalendarSourceRecord.connected(
                        id: stableID(prefix: "google-calendar", value: "\(calendar.accountIdentity)|\(calendar.externalIdentifier)"),
                        accountID: stableID(prefix: DesktopAccountRecord.Service.googleCalendar.rawValue, value: calendar.accountIdentity),
                        externalIdentifier: calendar.externalIdentifier,
                        provider: .google,
                        displayName: calendar.name,
                        ownerIdentity: calendar.accountIdentity,
                        accessLevel: discovered.first(where: { $0.identity == calendar.accountIdentity })?.supportsCalendarEventWrites == true
                            ? calendar.role
                            : "\(calendar.role) · reconnect for event changes",
                        isPrimary: calendar.isPrimary,
                        isEnabled: true
                    )
                }
                let appleSources = model.snapshot.domains.calendarSources.filter { $0.provider == .apple }
                model.replaceCalendarSources(appleSources + googleSources)
                lastIntegrationRefreshAt = .now
                if announce {
                    message = failedAccounts.isEmpty
                        ? "Refreshed \(discovered.count) Google account\(discovered.count == 1 ? "" : "s") and \(googleCalendars.count) calendar\(googleCalendars.count == 1 ? "" : "s")."
                        : "Refreshed \(discovered.count - failedAccounts.count) of \(discovered.count) Google accounts. Reconnect: \(failedAccounts.joined(separator: ", "))."
                }
            } catch {
                googleAccountLoadFailure = Self.savedGoogleAccountLoadFailure(error)
                if announce { message = googleAccountLoadFailure }
            }
            isRefreshingGoogle = false
        }
    }

    func connectGoogleAccount(model: DesktopAppModel) {
        guard !isConnectingGoogle else { return }
        isConnectingGoogle = true
        message = nil
        _Concurrency.Task {
            do {
#if os(macOS)
                let account = try await googleIntegration.connectAccount()
                message = "Connected \(account.identity). Refreshing its calendars…"
                isConnectingGoogle = false
                refreshGoogle(model: model)
#else
                message = "Google account connection is available in the desktop app."
                isConnectingGoogle = false
#endif
            } catch {
                message = error.localizedDescription
                isConnectingGoogle = false
            }
        }
    }

    func disconnectGoogleAccount(id: String, model: DesktopAppModel) {
        message = nil
        _Concurrency.Task {
            do {
                try await googleIntegration.disconnect(accountID: id)
                googleAccounts = try await googleIntegration.accounts()
                googleAccountLoadFailure = nil
                googleCalendars.removeAll { calendar in
                    !googleAccounts.contains { $0.identity == calendar.accountIdentity }
                }
                let gmailAccounts = googleAccounts.map { accountRecord(for: $0, service: .gmail) }
                let calendarAccounts = googleAccounts.map { accountRecord(for: $0, service: .googleCalendar) }
                model.replaceAccounts(for: [.gmail, .googleCalendar], with: gmailAccounts + calendarAccounts)
                let appleSources = model.snapshot.domains.calendarSources.filter { $0.provider == .apple }
                let googleSources = model.snapshot.domains.calendarSources.filter { source in
                    source.provider == .google && googleAccounts.contains { $0.identity == source.ownerIdentity }
                }
                model.replaceCalendarSources(appleSources + googleSources)
                message = "Google account disconnected from Kaname."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func reloadSavedGoogleAccounts(announce: Bool) async {
        do {
            googleAccounts = try await googleIntegration.accounts()
            googleAccountLoadFailure = nil
        } catch {
            googleAccountLoadFailure = Self.savedGoogleAccountLoadFailure(error)
            if announce { message = googleAccountLoadFailure }
        }
    }

    private static func savedGoogleAccountLoadFailure(_ error: Error) -> String {
        "Kaname could not load its saved Google account index. The saved connections were not removed. Retry loading them before reconnecting any account. (\(error.localizedDescription))"
    }

    func refreshInbox(model: DesktopAppModel) {
        guard !isRefreshingInbox else { return }
        let identities = model.snapshot.domains.accounts
            .filter { $0.service == .gmail && $0.status == .ready }
            .map(\.identity)
        guard !identities.isEmpty else {
            message = "Refresh Google accounts before reading the inbox."
            return
        }
        isRefreshingInbox = true
        message = nil
        _Concurrency.Task {
            var refreshedThreads: [PersonalMailThreadSnapshot] = []
            var failedAccounts: [String] = []
            for account in googleAccounts where identities.contains(account.identity) {
                do {
                    refreshedThreads.append(contentsOf: try await googleIntegration.listInbox(accountIDs: [account.id]))
                } catch {
                    failedAccounts.append(account.identity)
                }
            }
            mailThreads = refreshedThreads
            message = failedAccounts.isEmpty
                ? "Read \(mailThreads.count) inbox thread\(mailThreads.count == 1 ? "" : "s") across \(identities.count) account\(identities.count == 1 ? "" : "s")."
                : "Read \(mailThreads.count) inbox threads; reconnect \(failedAccounts.joined(separator: ", "))."
            isRefreshingInbox = false
        }
    }

    func refreshGitHub(model: DesktopAppModel, announce: Bool = true) {
        guard !isRefreshingGitHub else { return }
        isRefreshingGitHub = true
        if announce { message = nil }
        _Concurrency.Task {
            do {
                let access = try await integrations.inspectGitHubAccess()
                githubAccess = access
                model.replaceAccounts(
                    for: [.github],
                    with: [DesktopAccountRecord(
                        id: stableID(prefix: DesktopAccountRecord.Service.github.rawValue, value: access.login),
                        service: .github,
                        displayName: access.displayName,
                        identity: access.login,
                        status: .ready,
                        scope: "Current gh CLI host and token scope"
                    )]
                )
                lastIntegrationRefreshAt = .now
                if announce { message = "GitHub CLI access is ready for @\(access.login)." }
            } catch {
                if announce { message = error.localizedDescription }
            }
            isRefreshingGitHub = false
        }
    }

    func refreshProviders(announce: Bool = true) {
        guard !isRefreshingProviders else { return }
        isRefreshingProviders = true
        if announce { message = nil }
        _Concurrency.Task {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let definitions: [(String, ProviderDriverKind, String, String)] = [
                ("codexLocal", .codex, "Codex", "codex"),
                ("claudeLocal", .claudeAgent, "Claude", "claude"),
                ("opencodeLocal", .openCode, "OpenCode", "opencode"),
                ("cursorLocal", .cursorAgent, "Cursor", "cursor-agent"),
                ("grokLocal", .grokBuild, "Grok", "grok"),
            ]
            let prober = ProviderCapabilityProber()
            var results: [ProviderCapabilitySnapshot] = []
            for definition in definitions {
                guard let identifier = ProviderInstanceID(rawValue: definition.0) else { continue }
                let instance = ProviderInstance(id: identifier, driver: definition.1, displayName: definition.2)
                results.append(await prober.probe(ProviderProbeConfiguration(
                    instance: instance,
                    executable: definition.3,
                    workingDirectory: directory
                )))
            }
            providerCapabilities = results
            let checkedAt = results.map(\.checkedAt).max() ?? .now
            lastProviderRefreshAt = checkedAt
            try? await providerCache.save(ProviderCapabilityCacheSnapshot(
                capabilities: results,
                checkedAt: checkedAt
            ))
            let ready = results.filter { $0.state == .ready || $0.state == .degraded }.count
            if announce {
                message = "Refreshed \(results.count) native provider adapter\(results.count == 1 ? "" : "s"); \(ready) available."
            }
            isRefreshingProviders = false
        }
    }

    func requestAppleCalendarAccess(model: DesktopAppModel) {
        guard !isRequestingAppleCalendar else { return }
        isRequestingAppleCalendar = true
        message = nil
        _Concurrency.Task {
            do {
                let calendars = try await appleCalendar.requestAccessAndListCalendars()
                appleAccessState = appleCalendar.accessState
                applyAppleCalendars(calendars, model: model)
                lastIntegrationRefreshAt = .now
                message = calendars.isEmpty
                    ? "Apple Calendar access was not granted."
                    : "Loaded \(calendars.count) Apple calendar\(calendars.count == 1 ? "" : "s")."
            } catch {
                appleAccessState = appleCalendar.accessState
                message = error.localizedDescription
            }
            isRequestingAppleCalendar = false
        }
    }

    func refreshAppleCalendarStatus(model: DesktopAppModel, announce: Bool = true) {
        appleAccessState = appleCalendar.accessState
        guard appleAccessState == .ready else { return }
        let calendars = appleCalendar.listCalendarsIfAuthorized()
        applyAppleCalendars(calendars, model: model)
        lastIntegrationRefreshAt = .now
        if announce {
            message = "Refreshed \(calendars.count) authorized Apple calendar\(calendars.count == 1 ? "" : "s")."
        }
    }

    private func applyAppleCalendars(
        _ calendars: [AppleCalendarSourceSnapshot],
        model: DesktopAppModel
    ) {
        let sourceNames = Array(Set(calendars.map(\.sourceName))).sorted()
        let accounts = sourceNames.map { sourceName in
            DesktopAccountRecord(
                id: stableID(prefix: DesktopAccountRecord.Service.appleCalendar.rawValue, value: sourceName),
                service: .appleCalendar,
                displayName: sourceName,
                identity: sourceName,
                status: .ready,
                scope: "Calendars selected in Kaname settings"
            )
        }
        model.replaceAccounts(for: [.appleCalendar], with: accounts)
        let googleSources = model.snapshot.domains.calendarSources.filter { $0.provider == .google }
        let appleSources = calendars.map { calendar in
            DesktopCalendarSourceRecord.connected(
                id: stableID(prefix: "apple-calendar", value: calendar.externalIdentifier),
                accountID: stableID(prefix: DesktopAccountRecord.Service.appleCalendar.rawValue, value: calendar.sourceName),
                externalIdentifier: calendar.externalIdentifier,
                provider: .apple,
                displayName: calendar.name,
                ownerIdentity: calendar.sourceName,
                accessLevel: calendar.allowsChanges ? "read and write" : "read only",
                isPrimary: false,
                isEnabled: true
            )
        }
        model.replaceCalendarSources(googleSources + appleSources)
    }

    private func accountRecord(
        for account: NativeGoogleAccountSnapshot,
        service: DesktopAccountRecord.Service
    ) -> DesktopAccountRecord {
        DesktopAccountRecord(
            id: stableID(prefix: service.rawValue, value: account.identity),
            service: service,
            displayName: account.displayName,
            identity: account.identity,
            status: .ready,
            scope: account.capabilities.joined(separator: ", ")
        )
    }

    private func stableID(prefix: String, value: String) -> String {
        let encoded = Data(value.lowercased().utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(prefix)-\(encoded)"
    }
}
