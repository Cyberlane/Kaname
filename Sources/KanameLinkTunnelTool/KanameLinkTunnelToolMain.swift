#if os(macOS)
import Darwin
import Foundation
import KanameLinkTunnelHost

@main
struct KanameLinkTunnelToolMain {
    static func main() async {
        let credentialStore = KeychainKanameLinkTunnelCredentialStore()
        let runtime = KanameLinkTunnelToolRuntime(
            credentialAccess: KanameLinkTunnelToolKeychainCredentialAccess(
                store: credentialStore
            ),
            supervisorFactory: KanameLinkTunnelToolBridgeSupervisorFactory(
                store: credentialStore
            ),
            lifecycle: KanameLinkTunnelToolPOSIXRunLifecycle(),
            output: KanameLinkTunnelToolJSONLineOutput()
        )
        do {
            try await runtime.execute(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            let code = KanameLinkTunnelToolSafeFailure.code(for: error)
            if let receipt = try? KanameLinkTunnelToolJSON.encodeFailure(code: code) {
                try? FileHandle.standardError.write(contentsOf: receipt)
            }
            Darwin.exit(KanameLinkTunnelToolSafeFailure.exitCode(for: error))
        }
    }
}
#endif
