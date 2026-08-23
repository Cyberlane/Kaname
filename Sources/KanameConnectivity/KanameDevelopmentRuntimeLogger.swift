import Foundation

public enum KanameDevelopmentRuntimeLogEvent: String, Codable, Equatable, Sendable {
    case applicationStarted = "application_started"
    case applicationReady = "application_ready"
    case applicationWillTerminate = "application_will_terminate"
    case healthHandshakeFailed = "health_handshake_failed"
    case composerSelectionRecovered = "composer_selection_recovered"
}

public enum KanameDevelopmentRuntimeLogMeasurement: String, Codable, Hashable, Sendable {
    case draftCharacterCount
    case fallbackCursorOffset
}

public struct KanameDevelopmentRuntimeLogRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let unixMilliseconds: Int64
    public let sessionID: String
    public let component: String
    public let event: KanameDevelopmentRuntimeLogEvent
    public let processID: Int32
    public let measurements: [String: Int]
}

public final class KanameDevelopmentRuntimeLogger: @unchecked Sendable {
    public static let sessionEnvironmentKey = "KANAME_DEV_RUNTIME_SESSION_ID"
    public static let schemaEnvironmentKey = "KANAME_DEV_RUNTIME_LOG_SCHEMA_VERSION"
    public static let maximumBytesEnvironmentKey = "KANAME_DEV_RUNTIME_LOG_MAXIMUM_BYTES"
    public static let defaultMaximumBytes = 16 * 1_024 * 1_024

    public static let shared = KanameDevelopmentRuntimeLogger(
        enabled: KanameDesktopEnvironment.current.channel == .development,
        environment: ProcessInfo.processInfo.environment,
        processID: ProcessInfo.processInfo.processIdentifier,
        now: { Int64(Date().timeIntervalSince1970 * 1_000) },
        writer: { FileHandle.standardError.write($0) }
    )

    public let sessionID: String?
    public let maximumBytes: Int

    private let processID: Int32
    private let now: @Sendable () -> Int64
    private let writer: @Sendable (Data) -> Void
    private let stateLock = NSLock()
    private var bytesWritten = 0

    init(
        enabled: Bool,
        environment: [String: String],
        processID: Int32,
        now: @escaping @Sendable () -> Int64,
        writer: @escaping @Sendable (Data) -> Void
    ) {
        let declaredSession = environment[Self.sessionEnvironmentKey]
        let declaredSchema = environment[Self.schemaEnvironmentKey]
        if enabled,
           declaredSchema == String(KanameDevelopmentRuntimeLogRecord.currentSchemaVersion),
           let declaredSession,
           let identifier = UUID(uuidString: declaredSession) {
            sessionID = identifier.uuidString.lowercased()
        } else {
            sessionID = nil
        }

        let declaredMaximumBytes = environment[Self.maximumBytesEnvironmentKey].flatMap(Int.init)
        maximumBytes = min(max(declaredMaximumBytes ?? Self.defaultMaximumBytes, 1), Self.defaultMaximumBytes)
        self.processID = processID
        self.now = now
        self.writer = writer
    }

    public var isEnabled: Bool { sessionID != nil }

    @discardableResult
    public func record(
        _ event: KanameDevelopmentRuntimeLogEvent,
        measurements: [KanameDevelopmentRuntimeLogMeasurement: Int] = [:]
    ) -> Bool {
        guard let sessionID else { return false }
        let record = KanameDevelopmentRuntimeLogRecord(
            schemaVersion: KanameDevelopmentRuntimeLogRecord.currentSchemaVersion,
            unixMilliseconds: now(),
            sessionID: sessionID,
            component: "ui",
            event: event,
            processID: processID,
            measurements: Dictionary(uniqueKeysWithValues: measurements.map { ($0.key.rawValue, $0.value) })
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var encoded = try? encoder.encode(record) else { return false }
        encoded.append(0x0A)

        stateLock.lock()
        defer { stateLock.unlock() }
        guard encoded.count <= maximumBytes - bytesWritten else { return false }
        writer(encoded)
        bytesWritten += encoded.count
        return true
    }
}
