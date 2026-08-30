import Foundation
import Testing
@testable import KanameConnectivity

struct DesktopCodingTerminalIsolationTests {
    @Test
    func defaultTerminalsAreIsolatedPerThread() async throws {
        let service = DesktopCodingTerminalService()
        let cwd = FileManager.default.temporaryDirectory.path
        var terminalA = await service.ensureDefaultTerminal(
            threadID: "thread-a",
            cwd: cwd,
            nowUnixMillis: 1
        )
        var terminalB = await service.ensureDefaultTerminal(
            threadID: "thread-b",
            cwd: cwd,
            nowUnixMillis: 1
        )

        terminalA = await service.appendOutput(
            text: "private output from thread A\n",
            record: terminalA,
            nowUnixMillis: 2
        )
        terminalB = await service.ensureDefaultTerminal(
            threadID: "thread-b",
            cwd: cwd,
            nowUnixMillis: 2
        )

        #expect(terminalA.id == DesktopCodingTerminalRecord.defaultTerminalID)
        #expect(terminalB.id == DesktopCodingTerminalRecord.defaultTerminalID)
        #expect(terminalA.scrollbackExcerpt == "private output from thread A\n")
        #expect(terminalB.scrollbackExcerpt.isEmpty)

        terminalA = try await service.attachInteractive(updating: terminalA)
        terminalB = try await service.attachInteractive(updating: terminalB)

        #expect(terminalA.processID != nil)
        #expect(terminalB.processID != nil)
        #expect(terminalA.processID != terminalB.processID)

        _ = await service.closeInteractive(updating: terminalA)
        _ = await service.closeInteractive(updating: terminalB)
    }

    @Test
    func contextAttachmentCannotCrossThreads() async {
        let service = DesktopCodingTerminalService()
        var terminalA = await service.ensureDefaultTerminal(
            threadID: "thread-a",
            cwd: "/tmp/thread-a",
            nowUnixMillis: 1
        )
        terminalA = await service.appendOutput(
            text: "thread A secret\n",
            record: terminalA,
            nowUnixMillis: 2
        )
        let keyA = DesktopCodingTerminalKey(
            threadID: "thread-a",
            terminalID: DesktopCodingTerminalRecord.defaultTerminalID
        )
        let keyB = DesktopCodingTerminalKey(
            threadID: "thread-b",
            terminalID: DesktopCodingTerminalRecord.defaultTerminalID
        )

        let ownSource = await service.attachContextSource(key: keyA, from: terminalA)
        let crossThreadSource = await service.attachContextSource(key: keyB, from: terminalA)

        #expect(ownSource?.excerpt.contains("thread A secret") == true)
        #expect(ownSource?.path == "terminal:thread-a/term-1")
        #expect(crossThreadSource == nil)
    }
}
