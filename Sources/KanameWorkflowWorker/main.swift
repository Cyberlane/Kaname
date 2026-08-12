import Foundation
import KanameConnectivity
import KanameDesktop
import KanameWorkflowHost

@main
struct KanameWorkflowWorkerMain {
    private static func bundledGoogleConfiguration() -> GoogleOAuthClientConfiguration? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let infoURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let dictionary = NSDictionary(contentsOf: infoURL),
              let clientID = dictionary["KanameGoogleOAuthClientID"] as? String,
              !clientID.isEmpty else { return nil }
        let secret = (dictionary["KanameGoogleOAuthClientSecret"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return GoogleOAuthClientConfiguration.desktop(
            clientID: clientID,
            clientSecret: secret,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
        )
    }

    @MainActor
    static func main() async {
        do {
            // The desktop and worker share one durable workspace. The same
            // process lock makes their write ownership mutually exclusive;
            // when the UI is open it already performs these maintenance cycles.
            let channel: KanameDesktopEnvironment.Channel = CommandLine.arguments
                .firstIndex(of: "--channel")
                .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
                .flatMap(KanameDesktopEnvironment.Channel.init(rawValue:)) ?? .stable
            let environment = KanameDesktopEnvironment(channel: channel)
            let instanceLock = try KanameDesktopInstanceLock(lockFileURL: environment.instanceLockURL)
            let model = DesktopAppModel(store: FileDesktopStateStore(fileURL: environment.workspaceFileURL))
            guard !model.isRecoveryReadOnly else { return }
            let host = DesktopMailViewModel(
                environment: environment,
                googleClientConfiguration: bundledGoogleConfiguration()
            )
            await host.runWorkflowMaintenanceCycle(model: model)
            withExtendedLifetime(instanceLock) {}
        } catch KanameDesktopInstanceLockError.alreadyRunning {
            return
        } catch {
            FileHandle.standardError.write(Data("kaname-workflow-worker: maintenance cycle failed\n".utf8))
        }
    }
}
