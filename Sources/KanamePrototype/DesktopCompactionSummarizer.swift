import Foundation
import KanameDesktop
import KanameDomain

/// Compacts a thread immediately with the deterministic digest, then asks a
/// small model to rewrite that digest into a tighter hand-off summary and
/// swaps it in when it arrives. Uses the Claude Code CLI in tool-less print
/// mode with the fast model alias, the same way the workflow LLM host does;
/// when the CLI is missing or fails, the deterministic digest simply stays.
@MainActor
enum DesktopCompactionSummarizer {
    static func compact(_ model: DesktopAppModel, threadID: String) {
        guard model.compactThread(threadID: threadID),
              let thread = model.thread(id: threadID),
              let compaction = thread.compaction else { return }
        let deterministic = compaction.summary
        let transcript = olderTranscript(thread, throughMessageID: compaction.throughMessageID)
        let throughMessageID = compaction.throughMessageID
        _Concurrency.Task.detached(priority: .utility) {
            guard let summary = await summarize(deterministic: deterministic, transcript: transcript) else { return }
            await MainActor.run {
                model.updateCompactionSummary(threadID: threadID, throughMessageID: throughMessageID, summary: summary)
            }
        }
    }

    /// The messages the compaction hides, bounded so the prompt stays small.
    private static func olderTranscript(_ thread: DesktopThread, throughMessageID: String) -> String {
        var lines: [String] = []
        var budget = 40_000
        for message in thread.messages.reversed() where message.role != .system {
            let role = message.role == .user ? "User" : "Assistant"
            let body = KanameTextBounds.utf8Prefix(message.body.trimmingCharacters(in: .whitespacesAndNewlines), maximumBytes: 3_000)
            let line = "\(role): \(body)"
            budget -= line.utf8.count
            if budget < 0 { break }
            lines.append(line)
            if message.id == throughMessageID { break }
        }
        return lines.reversed().joined(separator: "\n\n")
    }

    private static func summarize(deterministic: String, transcript: String) async -> String? {
        guard let claude = resolve("claude") else { return nil }
        let prompt = """
        You are compacting a long coding conversation for the same assistant to continue from. Write a hand-off summary in Markdown, at most 350 words, with these sections when they apply: Goal, Decisions (with the reason for each), Current plan, Findings and facts learned, Open questions, and Where we are now (the exact next step). Keep identifiers, file paths, commands, and numbers exact. Do not add advice, do not address the user, output only the summary.

        Deterministic digest Kaname already produced:
        \(deterministic)

        Conversation being compacted:
        \(transcript)
        """
        return await run(
            executable: claude,
            arguments: [
                "-p", "--model", "haiku", "--output-format", "text",
                "--permission-mode", "plan", "--max-turns", "1", "--max-budget-usd", "0.50",
                "--disallowedTools", "Bash", "Edit", "Write", "Read", "Glob", "Grep", "WebFetch", "WebSearch", "Task", "NotebookEdit", "TodoWrite", "ToolSearch",
            ],
            input: prompt,
            timeout: 120
        )
    }

    private static func resolve(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local", "/usr/bin"] {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    private static func run(executable: URL, arguments: [String], input: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                let stdin = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = stdin
                var environment = ProcessInfo.processInfo.environment
                environment["CI"] = "1"
                environment["TERM"] = "dumb"
                environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"] ?? ""].joined(separator: ":")
                process.environment = environment
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { if process.isRunning { process.terminate() } }
                timer.resume()
                defer { timer.cancel() }
                do {
                    try process.run()
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.count >= 80 ? text : nil)
            }
        }
    }
}
