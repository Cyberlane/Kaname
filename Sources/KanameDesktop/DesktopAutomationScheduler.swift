import Foundation
#if os(macOS)
import Darwin
#endif

public enum DesktopScheduleError: Error, Equatable, LocalizedError {
    case invalidTimeZone
    case invalidComponents
    case noFutureOccurrence
    case leaseUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidTimeZone: "The schedule time zone is invalid."
        case .invalidComponents: "The schedule contains an invalid time or weekday."
        case .noFutureOccurrence: "The schedule has no future occurrence."
        case .leaseUnavailable: "Another Kaname scheduler owns the current execution lease."
        }
    }
}

public enum DesktopScheduleEngine {
    public static func nextOccurrence(
        spec: DesktopScheduleSpec,
        timeZoneIdentifier: String,
        after unixMillis: Int64
    ) throws -> Int64? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { throw DesktopScheduleError.invalidTimeZone }
        guard (0...23).contains(spec.hour), (0...59).contains(spec.minute) else { throw DesktopScheduleError.invalidComponents }
        if spec.frequency == .once {
            guard let once = spec.onceAtUnixMillis else { throw DesktopScheduleError.invalidComponents }
            return once > unixMillis ? once : nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        var components = DateComponents(hour: spec.hour, minute: spec.minute, second: 0)
        if spec.frequency == .weekly {
            guard let weekday = spec.weekday, (1...7).contains(weekday) else { throw DesktopScheduleError.invalidComponents }
            components.weekday = weekday
        }
        let after = Date(timeIntervalSince1970: Double(unixMillis) / 1_000)
        let next = calendar.nextDate(
            after: after,
            matching: components,
            matchingPolicy: .nextTimePreservingSmallerComponents,
            repeatedTimePolicy: .first,
            direction: .forward
        )
        return next.map { Int64($0.timeIntervalSince1970 * 1_000) }
    }

    public static func deduplicationKey(automationID: String, scheduledAtUnixMillis: Int64) -> String {
        "automation:\(automationID):scheduled:\(scheduledAtUnixMillis)"
    }

    public static func humanSchedule(spec: DesktopScheduleSpec, timeZoneIdentifier: String) -> String {
        let time = String(format: "%02d:%02d", spec.hour, spec.minute)
        switch spec.frequency {
        case .once:
            guard let value = spec.onceAtUnixMillis else { return "Once (date missing)" }
            return "Once at \(Date(timeIntervalSince1970: Double(value) / 1_000).formatted())"
        case .daily:
            return "Daily at \(time) · \(timeZoneIdentifier)"
        case .weekly:
            let symbols = Calendar(identifier: .gregorian).weekdaySymbols
            let day = spec.weekday.flatMap { (1...7).contains($0) ? symbols[$0 - 1] : nil } ?? "weekday"
            return "Every \(day) at \(time) · \(timeZoneIdentifier)"
        }
    }
}

public struct DesktopSchedulerLease: Codable, Equatable, Sendable {
    public let ownerID: String
    public let processID: Int32
    public let acquiredAtUnixMillis: Int64
    public let expiresAtUnixMillis: Int64
}

public final class DesktopSchedulerLeaseStore: @unchecked Sendable {
    private let fileURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var lockDescriptor: Int32 = -1
    private var lockOwnerID: String?

    public init(directory: URL, fileManager: FileManager = .default) {
        fileURL = directory.appending(path: "scheduler-lease.json")
        lockURL = directory.appending(path: "scheduler-owner.lock")
        self.fileManager = fileManager
    }

    deinit {
        #if os(macOS)
        if lockDescriptor >= 0 {
            _ = flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
        #endif
    }

    public func acquire(ownerID: String, nowUnixMillis: Int64, durationMillis: Int64 = 90_000) throws -> DesktopSchedulerLease {
        stateLock.lock()
        defer { stateLock.unlock() }
        try prepareDirectory()
        if lockDescriptor >= 0 {
            guard lockOwnerID == ownerID else { throw DesktopScheduleError.leaseUnavailable }
            return try writeLease(ownerID: ownerID, nowUnixMillis: nowUnixMillis, durationMillis: durationMillis)
        }
        #if os(macOS)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DesktopScheduleError.leaseUnavailable }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw DesktopScheduleError.leaseUnavailable
        }
        lockDescriptor = descriptor
        lockOwnerID = ownerID
        #else
        throw DesktopScheduleError.leaseUnavailable
        #endif
        return try writeLease(ownerID: ownerID, nowUnixMillis: nowUnixMillis, durationMillis: durationMillis)
    }

    private func writeLease(ownerID: String, nowUnixMillis: Int64, durationMillis: Int64) throws -> DesktopSchedulerLease {
        let lease = DesktopSchedulerLease(
            ownerID: ownerID,
            processID: ProcessInfo.processInfo.processIdentifier,
            acquiredAtUnixMillis: nowUnixMillis,
            expiresAtUnixMillis: nowUnixMillis + durationMillis
        )
        let temporary = fileURL.appendingPathExtension("\(ownerID).tmp")
        try JSONEncoder().encode(lease).write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: fileURL.path) { _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary) }
        else { try fileManager.moveItem(at: temporary, to: fileURL) }
        return lease
    }

    public func load() throws -> DesktopSchedulerLease {
        try JSONDecoder().decode(DesktopSchedulerLease.self, from: Data(contentsOf: fileURL))
    }

    public func release(ownerID: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lockDescriptor >= 0, lockOwnerID == ownerID else { return }
        try? fileManager.removeItem(at: fileURL)
        #if os(macOS)
        _ = flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
        #endif
        lockDescriptor = -1
        lockOwnerID = nil
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: lockURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try fileManager.removeItem(at: lockURL)
        }
    }
}
