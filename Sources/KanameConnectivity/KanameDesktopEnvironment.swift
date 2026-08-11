import Foundation

public struct KanameDesktopEnvironment: Equatable, Sendable {
    public enum Channel: String, Codable, Sendable {
        case stable
        case candidate
    }

    public let channel: Channel
    public let applicationSupportRoot: URL

    public init(channel: Channel, applicationSupportDirectory: URL? = nil) {
        self.channel = channel
        let base = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        applicationSupportRoot = base.appending(
            path: channel == .stable ? "Kaname" : "Kaname Candidate",
            directoryHint: .isDirectory
        )
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
        channel == .stable ? "com.cyberlane.kaname.desktop" : "com.cyberlane.kaname.desktop.candidate"
    }

    public var displayName: String { channel == .stable ? "Kaname" : "Kaname Candidate" }
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
    public var instanceLockURL: URL { runtimeDirectory.appending(path: "desktop-instance.lock") }
    public var updateDirectory: URL { applicationSupportRoot.appending(path: "Updates", directoryHint: .isDirectory) }
    public var dogfoodUpdateDirectory: URL { updateDirectory.appending(path: "Dogfood", directoryHint: .isDirectory) }
    public var dogfoodUpdateCatalogURL: URL { dogfoodUpdateDirectory.appending(path: "catalog.json") }
    public var dogfoodUpdatePreferencesURL: URL { dogfoodUpdateDirectory.appending(path: "preferences.json") }
    public var worktreeDirectory: URL { applicationSupportRoot.appending(path: "Worktrees", directoryHint: .isDirectory) }
    public var healthHandshakeURL: URL { runtimeDirectory.appending(path: "ui-health.json") }
}
