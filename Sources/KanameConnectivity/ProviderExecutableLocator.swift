import Foundation

public enum ProviderExecutableLocator {
    public static func url(named executable: String) -> URL? {
        LocalProcess.resolveExecutable(named: executable)
    }
}
