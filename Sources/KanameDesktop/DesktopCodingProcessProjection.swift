import Foundation
import KanameDomain

/// One command the provider ran during a thread, reconstructed from the
/// durable provider event records. Claude reports commands as `Bash` tool
/// calls (tool_use / tool_result blocks); Codex reports `commandExecution`
/// items with aggregated output. Both are projected onto this shape so the
/// Processes tab can show what ran, whether it succeeded, and what it printed.
public struct DesktopCodingProcessRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let runID: String
    public var command: String
    public var summary: String?
    public var state: ProviderToolState
    public var exitCode: Int?
    public var output: String
    public var outputWasTruncated: Bool
    public let startedAtUnixMillis: Int64
    public var endedAtUnixMillis: Int64?

    public static let maximumOutputBytes = 48 * 1_024

    public var durationLabel: String? {
        guard let endedAtUnixMillis else { return nil }
        let millis = max(0, endedAtUnixMillis - startedAtUnixMillis)
        if millis < 1_000 { return "\(millis) ms" }
        let seconds = millis / 1_000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    public var isRunning: Bool { state == .running }
}

public enum DesktopCodingProcessProjection {
    public static func processes(from events: [DesktopProviderEventRecord]) -> [DesktopCodingProcessRecord] {
        var order: [String] = []
        var records: [String: DesktopCodingProcessRecord] = [:]
        for event in events.sorted(by: { $0.createdAtUnixMillis < $1.createdAtUnixMillis }) {
            guard let observation = event.toolObservation, isCommand(observation) else { continue }
            let payload = event.rawPayloadBase64
                .flatMap { Data(base64Encoded: $0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let facts = extract(callID: observation.callID, from: payload)
            if var existing = records[observation.callID] {
                if existing.command.isEmpty, let command = facts.command { existing.command = command }
                if existing.summary == nil { existing.summary = facts.summary }
                if let output = facts.output, !output.isEmpty {
                    existing.output = facts.outputIsAggregate ? output : existing.output + output
                    if existing.output.utf8.count > DesktopCodingProcessRecord.maximumOutputBytes {
                        existing.output = String(decoding: Array(existing.output.utf8.prefix(DesktopCodingProcessRecord.maximumOutputBytes)), as: UTF8.self)
                        existing.outputWasTruncated = true
                    }
                }
                if let exitCode = facts.exitCode { existing.exitCode = exitCode }
                if observation.state != .running || existing.state == .running {
                    existing.state = observation.state
                }
                if observation.state != .running {
                    existing.endedAtUnixMillis = event.createdAtUnixMillis
                }
                existing.outputWasTruncated = existing.outputWasTruncated || event.payloadWasTruncated
                records[observation.callID] = existing
            } else {
                order.append(observation.callID)
                records[observation.callID] = DesktopCodingProcessRecord(
                    id: observation.callID,
                    runID: event.runID,
                    command: facts.command ?? observation.name ?? "command",
                    summary: facts.summary,
                    state: observation.state,
                    exitCode: facts.exitCode,
                    output: facts.output ?? "",
                    outputWasTruncated: event.payloadWasTruncated,
                    startedAtUnixMillis: event.createdAtUnixMillis,
                    endedAtUnixMillis: observation.state == .running ? nil : event.createdAtUnixMillis
                )
            }
        }
        return order.compactMap { records[$0] }
    }

    private static func isCommand(_ observation: ProviderToolObservation) -> Bool {
        if observation.kind == .commandExecution { return true }
        guard let name = observation.name?.lowercased() else { return false }
        return ["bash", "shell", "powershell", "run_terminal_cmd"].contains(name)
    }

    private struct Facts {
        var command: String?
        var summary: String?
        var output: String?
        var outputIsAggregate = false
        var exitCode: Int?
    }

    private static func extract(callID: String, from payload: Any?) -> Facts {
        var facts = Facts()
        guard let payload else { return facts }
        // Claude: the block whose id / tool_use_id matches this call.
        if let block = findDictionary(in: payload, where: { dictionary in
            (dictionary["id"] as? String) == callID || (dictionary["tool_use_id"] as? String) == callID
        }) {
            if let input = block["input"] as? [String: Any] {
                facts.command = string(input["command"]) ?? string(input["cmd"])
                facts.summary = input["description"] as? String
            }
            if let content = block["content"] {
                facts.output = text(from: content)
                facts.outputIsAggregate = true
            }
            if block["is_error"] as? Bool == true, facts.exitCode == nil { facts.exitCode = 1 }
        }
        // Codex: item.command / item.aggregatedOutput / item.exitCode.
        if let item = (payload as? [String: Any])?["item"] as? [String: Any] {
            facts.command = facts.command ?? string(item["command"])
            facts.summary = facts.summary ?? (item["cwd"] as? String).map { "cwd \($0)" }
            if let output = string(item["aggregatedOutput"]) ?? string(item["aggregated_output"]) ?? string(item["output"]) {
                facts.output = output
                facts.outputIsAggregate = true
            }
            facts.exitCode = facts.exitCode ?? (item["exitCode"] as? Int) ?? (item["exit_code"] as? Int)
        }
        if let delta = (payload as? [String: Any])?["delta"] as? String, facts.output == nil {
            facts.output = delta
        }
        return facts
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let parts as [Any]: return parts.compactMap { $0 as? String }.joined(separator: " ")
        default: return nil
        }
    }

    private static func text(from content: Any) -> String? {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func findDictionary(
        in value: Any,
        where predicate: ([String: Any]) -> Bool
    ) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if predicate(dictionary) { return dictionary }
            for child in dictionary.values {
                if let found = findDictionary(in: child, where: predicate) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findDictionary(in: child, where: predicate) { return found }
            }
        }
        return nil
    }
}

public extension String {
    /// Removes ANSI escape sequences so terminal output reads cleanly in a text view.
    var strippingANSIEscapes: String {
        replacingOccurrences(
            of: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]|\u{1B}\][^\u{07}]*\u{07}|\u{1B}[@-Z\\-_]"#,
            with: "",
            options: .regularExpression
        )
    }
}
