#if canImport(EventKit)
import EventKit
import Foundation

public enum AppleCalendarAccessState: String, Equatable, Sendable {
    case notRequested
    case denied
    case restricted
    case writeOnly
    case ready
    case unavailable
}

public struct AppleCalendarSourceSnapshot: Equatable, Sendable {
    public let externalIdentifier: String
    public let name: String
    public let sourceName: String
    public let allowsChanges: Bool
}

@MainActor
public final class AppleCalendarIntegrationService {
    private let store: EKEventStore

    public init() {
        store = EKEventStore()
    }

    public var accessState: AppleCalendarAccessState {
        Self.accessState(for: EKEventStore.authorizationStatus(for: .event))
    }

    public func requestAccessAndListCalendars() async throws -> [AppleCalendarSourceSnapshot] {
        let granted: Bool
        if #available(macOS 14.0, iOS 17.0, *) {
            granted = try await store.requestFullAccessToEvents()
        } else {
            granted = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { allowed, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: allowed)
                    }
                }
            }
        }
        guard granted else { return [] }
        return store.calendars(for: .event).map {
            AppleCalendarSourceSnapshot(
                externalIdentifier: $0.calendarIdentifier,
                name: $0.title,
                sourceName: $0.source.title,
                allowsChanges: $0.allowsContentModifications
            )
        }.sorted {
            "\($0.sourceName)|\($0.name)".localizedCaseInsensitiveCompare(
                "\($1.sourceName)|\($1.name)"
            ) == .orderedAscending
        }
    }

    nonisolated static func accessState(for status: EKAuthorizationStatus) -> AppleCalendarAccessState {
        let mapping: [EKAuthorizationStatus: AppleCalendarAccessState] = [
            .notDetermined: .notRequested,
            .restricted: .restricted,
            .denied: .denied,
            .writeOnly: .writeOnly,
            .fullAccess: .ready,
            .authorized: .ready,
        ]
        return mapping[status] ?? .unavailable
    }
}
#endif
