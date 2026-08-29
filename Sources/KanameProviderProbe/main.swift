import Foundation
import KanameConnectivity
import KanameDomain

@main
struct KanameProviderProbeCommand {
    static func main() async {
        let requested = Array(CommandLine.arguments.dropFirst())
        let drivers = requested.isEmpty || requested == ["all"]
            ? [ProviderDriverKind.codex, .claudeAgent, .openCode, .cursorAgent, .grokBuild]
            : requested.compactMap(ProviderDriverKind.init(rawValue:))

        guard !drivers.isEmpty else {
            FileHandle.standardError.write(Data("Usage: swift run KanameProviderProbe [all|codex|claudeAgent|opencode|cursorAgent|grokBuild]\n".utf8))
            return
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let prober = ProviderCapabilityProber()
        let snapshots = await drivers.asyncMap { driver in
            let instance = ProviderInstance(
                id: ProviderInstanceID(rawValue: "\(driver.rawValue)_local")!,
                driver: driver,
                displayName: "\(driver.rawValue) local"
            )
            let executable: String = switch driver {
            case .codex: "codex"
            case .claudeAgent: "claude"
            case .openCode: "opencode"
            case .cursorAgent: "cursor-agent"
            case .grokBuild: "grok"
            default: driver.rawValue
            }
            return await prober.probe(ProviderProbeConfiguration(
                instance: instance,
                executable: executable,
                workingDirectory: currentDirectory
            ))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        for snapshot in snapshots {
            guard let data = try? encoder.encode(snapshot) else { continue }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

private extension Array {
    func asyncMap<T: Sendable>(_ transform: @escaping @Sendable (Element) async -> T) async -> [T] where Element: Sendable {
        await withTaskGroup(of: (Int, T).self) { group in
            for (index, element) in enumerated() {
                group.addTask {
                    (index, await transform(element))
                }
            }

            var ordered = Array<T?>(repeating: nil, count: count)
            for await (index, value) in group {
                ordered[index] = value
            }
            return ordered.compactMap { $0 }
        }
    }
}
