import Foundation

public enum KanameExternalMutationPolicy: String, Codable, Equatable, Sendable {
    case allowed
    case denied
}

public struct KanameDesktopEnvironment: Equatable, Sendable {
    public enum Channel: String, Codable, Sendable {
        case stable
        case candidate
        case development
    }

    public let channel: Channel
    public let applicationSupportRoot: URL

    public init(channel: Channel, applicationSupportDirectory: URL? = nil) {
        self.channel = channel
        let base = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let applicationSupportName = switch channel {
        case .stable: "Kaname"
        case .candidate: "Kaname Candidate"
        case .development: "Kaname Dev"
        }
        applicationSupportRoot = base.appending(path: applicationSupportName, directoryHint: .isDirectory)
    }

    public static var current: KanameDesktopEnvironment {
        let declared = Bundle.main.object(forInfoDictionaryKey: "KanameDesktopChannel") as? String
        let qaSupportDirectory = qaApplicationSupportDirectory(arguments: CommandLine.arguments)
        return KanameDesktopEnvironment(
            channel: Channel(rawValue: declared ?? "") ?? .stable,
            applicationSupportDirectory: qaSupportDirectory
        )
    }

    static func qaApplicationSupportDirectory(arguments: [String]) -> URL? {
        arguments.firstIndex(of: "--desktop-qa-application-support-base")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            .flatMap { path -> URL? in
                guard path.hasPrefix("/"), path != "/" else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
    }

    public var bundleIdentifier: String {
        switch channel {
        case .stable: "com.cyberlane.kaname.desktop"
        case .candidate: "com.cyberlane.kaname.desktop.candidate"
        case .development: "com.cyberlane.kaname.desktop.dev"
        }
    }

    public static func desktopUIInstanceLockURL(
        applicationSupportDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    ) -> URL {
        applicationSupportDirectory
            .appending(path: "Kaname Runtime", directoryHint: .isDirectory)
            .appending(path: "desktop-ui-instance.lock", directoryHint: .notDirectory)
    }

    public var displayName: String {
        switch channel {
        case .stable: "Kaname"
        case .candidate: "Kaname Candidate"
        case .development: "Kaname - Dev"
        }
    }
    public var externalMutationPolicy: KanameExternalMutationPolicy {
        channel == .development ? .denied : .allowed
    }
    public var allowsExternalMutations: Bool { externalMutationPolicy == .allowed }
    public var allowsAutomaticExecution: Bool { channel != .development }
    public var googleIntegrationAccessMode: GoogleIntegrationAccessMode {
        channel == .development ? .readOnly : .readWrite
    }
    public var localCoreMachService: String { "\(bundleIdentifier).localcore.service" }
    public var googleKeychainService: String { "\(bundleIdentifier).google-oauth" }
    public var activationNotificationName: String { "\(bundleIdentifier).activate-existing-instance" }
    public var desktopDirectory: URL { applicationSupportRoot.appending(path: "Desktop", directoryHint: .isDirectory) }
    public var workspaceFileURL: URL { desktopDirectory.appending(path: "workspace.json") }
    public var providerStateDirectory: URL { desktopDirectory.appending(path: "Codex", directoryHint: .isDirectory) }
    public var standaloneWorkspaceDirectory: URL { desktopDirectory.appending(path: "Standalone", directoryHint: .isDirectory) }
    public var connectivityDirectory: URL { applicationSupportRoot.appending(path: "Connectivity", directoryHint: .isDirectory) }
    public var googleDirectory: URL { applicationSupportRoot.appending(path: "Google", directoryHint: .isDirectory) }
    public var runtimeDirectory: URL { applicationSupportRoot.appending(path: "Runtime", directoryHint: .isDirectory) }
    public var desktopUIInstanceLockURL: URL { Self.desktopUIInstanceLockURL() }
    public var instanceLockURL: URL { runtimeDirectory.appending(path: "desktop-instance.lock") }
    public var updateDirectory: URL { applicationSupportRoot.appending(path: "Updates", directoryHint: .isDirectory) }
    public var dogfoodUpdateDirectory: URL { updateDirectory.appending(path: "Dogfood", directoryHint: .isDirectory) }
    public var dogfoodUpdateCatalogURL: URL { dogfoodUpdateDirectory.appending(path: "catalog.json") }
    public var dogfoodUpdatePreferencesURL: URL { dogfoodUpdateDirectory.appending(path: "preferences.json") }
    public var worktreeDirectory: URL { applicationSupportRoot.appending(path: "Worktrees", directoryHint: .isDirectory) }
    public var healthHandshakeURL: URL { runtimeDirectory.appending(path: "ui-health.json") }
}
