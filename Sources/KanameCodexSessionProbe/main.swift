import Foundation
import Darwin
import KanameConnectivity
import KanameDomain

private struct ProbeEvent: Codable {
    let kind: String
    let nativeType: String
    let threadID: String?
    let turnID: String?
    let text: String?
    let retainedPayloadBytes: Int
    let payloadWasTruncated: Bool
}

@main
private struct KanameCodexSessionProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Kaname Codex session probe failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let workspace = workspaceURL(arguments: Array(CommandLine.arguments.dropFirst()))
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "codexLocal")!,
            driver: .codex,
            displayName: "Codex local"
        )
        let session = CodexLiveSession(configuration: .init(instance: instance, workspaceURL: workspace))
        let events = await session.events()

        let request = CodexCodingRequest(
            prompt: prompt(arguments: Array(CommandLine.arguments.dropFirst())),
            model: "gpt-5.6-terra",
            reasoningEffort: "xhigh",
            sandbox: .readOnly
        )
        _ = try await session.start(request)

        for await event in events {
            guard shouldRender(event) else { continue }
            write(ProbeEvent(
                kind: event.kind.rawValue,
                nativeType: event.nativeType,
                threadID: event.threadID,
                turnID: event.turnID,
                text: event.kind == .itemCompleted ? event.text : nil,
                retainedPayloadBytes: event.payload?.count ?? 0,
                payloadWasTruncated: event.payloadWasTruncated
            ))
            if event.kind == .providerCompleted || event.kind == .runFailed || event.kind == .runInterrupted {
                await session.close()
                break
            }
        }
        await session.close()
    }

    private static func shouldRender(_ event: CodexRunEvent) -> Bool {
        switch event.kind {
        case .sessionStarted, .runStarted, .providerCompleted, .runFailed, .runInterrupted,
             .approvalRequested, .approvalAccepted, .approvalRejected,
             .questionRequested, .questionAnswered:
            true
        case .itemCompleted, .planUpdated, .toolActivity, .diffUpdated:
            event.text != nil
        case .messageDelta, .itemStarted, .nativeProviderEvent:
            false
        }
    }

    private static func workspaceURL(arguments: [String]) -> URL {
        guard let index = arguments.firstIndex(of: "--workspace"),
              arguments.indices.contains(index + 1)
        else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    private static func prompt(arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "--prompt"),
              arguments.indices.contains(index + 1)
        else {
            return """
            Review the current Kaname worktree's Codex live-session adapter for correctness and safety. Do not modify files, do not use the network, and do not ask for additional permissions. Return a concise review covering protocol assumptions, event/approval handling, and the most important missing verification.
            """
        }
        return arguments[index + 1]
    }

    private static func write(_ event: ProbeEvent) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
