import Foundation
@testable import KanameConnectivity
import Testing

struct KanameDevelopmentRuntimeLoggerTests {
    @Test
    func loggerWritesOnlyStructuredMetadataForAValidDevelopmentSession() throws {
        let buffer = DevelopmentLogBuffer()
        let logger = makeLogger(buffer: buffer)

        #expect(logger.record(
            .composerSelectionRecovered,
            measurements: [
                .draftCharacterCount: 4,
                .fallbackCursorOffset: 2,
            ]
        ))

        let data = buffer.data
        let line = try #require(data.split(separator: 0x0A).first)
        let record = try JSONDecoder().decode(KanameDevelopmentRuntimeLogRecord.self, from: Data(line))
        #expect(record.schemaVersion == 1)
        #expect(record.sessionID == "11111111-2222-3333-4444-555555555555")
        #expect(record.component == "ui")
        #expect(record.event == .composerSelectionRecovered)
        #expect(record.processID == 73)
        #expect(record.unixMilliseconds == 1_234)
        #expect(record.measurements == [
            "draftCharacterCount": 4,
            "fallbackCursorOffset": 2,
        ])
        #expect(!String(decoding: data, as: UTF8.self).contains("prompt"))
    }

    @Test
    func loggerRequiresBothDevelopmentAndAnExactSessionContract() {
        for configuration in [
            (enabled: true, sessionID: "not-a-uuid"),
            (enabled: false, sessionID: "11111111-2222-3333-4444-555555555555"),
        ] {
            let buffer = DevelopmentLogBuffer()
            let logger = KanameDevelopmentRuntimeLogger(
                enabled: configuration.enabled,
                environment: [
                    KanameDevelopmentRuntimeLogger.sessionEnvironmentKey: configuration.sessionID,
                    KanameDevelopmentRuntimeLogger.schemaEnvironmentKey: "1",
                ],
                processID: 73,
                now: { 1_234 },
                writer: buffer.append
            )

            #expect(!logger.isEnabled)
            #expect(!logger.record(.applicationStarted))
            #expect(buffer.data.isEmpty)
        }
    }

    @Test
    func loggerStopsBeforeItsDeclaredByteLimit() {
        let buffer = DevelopmentLogBuffer()
        let logger = makeLogger(buffer: buffer, maximumBytes: 1)

        #expect(!logger.record(.applicationStarted))
        #expect(buffer.data.isEmpty)
    }

    private func makeLogger(
        buffer: DevelopmentLogBuffer,
        maximumBytes: Int = KanameDevelopmentRuntimeLogger.defaultMaximumBytes
    ) -> KanameDevelopmentRuntimeLogger {
        KanameDevelopmentRuntimeLogger(
            enabled: true,
            environment: [
                KanameDevelopmentRuntimeLogger.sessionEnvironmentKey: "11111111-2222-3333-4444-555555555555",
                KanameDevelopmentRuntimeLogger.schemaEnvironmentKey: "1",
                KanameDevelopmentRuntimeLogger.maximumBytesEnvironmentKey: String(maximumBytes),
            ],
            processID: 73,
            now: { 1_234 },
            writer: buffer.append
        )
    }
}

private final class DevelopmentLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(data)
    }
}
