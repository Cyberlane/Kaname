import Foundation
import KanameConnectivity

@main
struct KanameDogfoodUpdatePublisherCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2 else {
                throw CommandError.usage
            }
            let bundleURL = URL(fileURLWithPath: arguments[0], isDirectory: true)
            let installedBundleURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let publisher = KanameLocalDogfoodUpdatePublisher(installedBundleURL: installedBundleURL)
            let receipt = try await publisher.publish(bundleURL: bundleURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(receipt))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private enum CommandError: LocalizedError {
        case usage

        var errorDescription: String? {
            "usage: KanameDogfoodUpdatePublisher <new-stable.app> <installed-stable.app>"
        }
    }
}
