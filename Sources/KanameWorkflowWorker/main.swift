import Foundation
import KanameConnectivity
import KanameDesktop
import KanameLocalCore
import KanameWorkflowHost
import Darwin

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
            // The legacy worker and desktop share one durable workspace. The
            // automation service mode below uses its own runtime lock and only
            // reads the Rust projection, so it can run while the UI is open.
            let channelValue = CommandLine.arguments
                .firstIndex(of: "--channel")
                .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
            guard let channel = channelValue.flatMap(KanameDesktopEnvironment.Channel.init(rawValue:)) else { return }
            let supportBase = CommandLine.arguments
                .firstIndex(of: "--application-support-base")
                .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
                .flatMap { path -> URL? in
                    guard path.hasPrefix("/"), path != "/" else { return nil }
                    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                }
            let environment = KanameDesktopEnvironment(
                channel: channel, applicationSupportDirectory: supportBase
            )
            if CommandLine.arguments.contains("--automation-service") {
                guard let supportBase,
                      let machService = argumentValue(after: "--mach-service"),
                      let serviceRequirement = argumentValue(after: "--service-requirement"),
                      let parentValue = argumentValue(after: "--parent-pid"),
                      let parentPID = Int32(parentValue), parentPID > 0 else { return }
                let runner = LocalCoreRunner(
                    machService: machService, serviceRequirement: serviceRequirement
                )
                let explicitEnvironment = KanameDesktopEnvironment(
                    channel: channel, applicationSupportDirectory: supportBase
                )
                try await runAutomationService(
                    environment: explicitEnvironment, runner: runner, parentPID: parentPID
                )
                return
            }
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

    private static func argumentValue(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func runAutomationService(
        environment: KanameDesktopEnvironment,
        runner: LocalCoreRunner,
        parentPID: Int32
    ) async throws {
        guard getppid() == parentPID else { return }
        let lock = try KanameDesktopInstanceLock(lockFileURL: environment.automationServiceLockURL)
        let service = DesktopAutomationService(environment: environment, runner: runner)
        let googleConfiguration = bundledGoogleConfiguration()
        DesktopWorkflowConnectorBridge.shared.start(
            environment: environment, googleClientConfiguration: googleConfiguration
        )
        DesktopMailEventPoller.shared.start(
            environment: environment, runner: runner, googleClientConfiguration: googleConfiguration
        )
        DesktopCalendarEventPoller.shared.start(
            environment: environment, runner: runner, googleClientConfiguration: googleConfiguration
        )
        await service.runOnce()
        defer { DesktopWorkflowConnectorBridge.shared.stop() }
        while !_Concurrency.Task.isCancelled {
            guard getppid() == parentPID else { return }
            do {
                try await _Concurrency.Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard !_Concurrency.Task.isCancelled, getppid() == parentPID else { return }
            await service.runOnce()
        }
        withExtendedLifetime(lock) {}
    }
}
