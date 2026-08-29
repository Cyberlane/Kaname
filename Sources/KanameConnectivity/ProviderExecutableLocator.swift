import Foundation

public enum ProviderExecutableLocator {
    public static func url(named executable: String) -> URL? {
        LocalProcess.resolveExecutable(named: executable)
    }

    /// Resolves an installed CLI name for a native conversation driver.
    /// Cursor may ship as `cursor-agent` or `agent`; prefer the first found.
    public static func resolveNativeConversationExecutable(
        for driver: NativeConversationDriver
    ) -> String {
        let candidates: [String]
        switch driver {
        case .cursor:
            candidates = ["cursor-agent", "agent"]
        case .claude, .openCode, .grok:
            candidates = [driver.executableName]
        }
        return candidates.first(where: { url(named: $0) != nil }) ?? driver.executableName
    }
}
