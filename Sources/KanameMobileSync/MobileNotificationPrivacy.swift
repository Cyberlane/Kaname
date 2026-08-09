import Foundation
import KanameProtocol

public enum MobileNotificationDataClass: String, Codable, CaseIterable, Sendable {
    case publicRepository
    case privateRepository
    case personalKnowledge
    case email
    case calendar
    case providerConversation
    case deviceSync
    case audit
}

public enum MobileNotificationPreviewLevel: String, Codable, CaseIterable, Sendable {
    case hidden
    case categoryOnly
    case safeDetail
}

public struct MobileNotificationPrivacySettings: Codable, Equatable, Sendable {
    public var levels: [MobileNotificationDataClass: MobileNotificationPreviewLevel]

    public init(
        levels: [MobileNotificationDataClass: MobileNotificationPreviewLevel] = [:]
    ) {
        self.levels = levels
    }

    public static let privacyFirst = MobileNotificationPrivacySettings(
        levels: Dictionary(
            uniqueKeysWithValues: MobileNotificationDataClass.allCases.map { ($0, .hidden) }
        )
    )

    public func level(for dataClass: MobileNotificationDataClass) -> MobileNotificationPreviewLevel {
        levels[dataClass] ?? .hidden
    }

    public mutating func setLevel(
        _ level: MobileNotificationPreviewLevel,
        for dataClass: MobileNotificationDataClass
    ) {
        levels[dataClass] = level
    }
}

public struct MobileSafeNotificationContent: Codable, Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public enum MobileNotificationPreviewRenderer {
    public static func content(
        level: MobileNotificationPreviewLevel,
        dataClass: MobileNotificationDataClass,
        safePreviewClass: String
    ) -> MobileSafeNotificationContent {
        switch level {
        case .hidden:
            MobileSafeNotificationContent(
                title: "Kaname",
                body: "Open Kaname to view this update."
            )
        case .categoryOnly:
            MobileSafeNotificationContent(
                title: dataClass.safeTitle,
                body: "Attention is available in Kaname."
            )
        case .safeDetail:
            MobileSafeNotificationContent(
                title: dataClass.safeTitle,
                body: safeBody(for: safePreviewClass)
            )
        }
    }

    private static func safeBody(for safePreviewClass: String) -> String {
        switch safePreviewClass {
        case "approval-required": "A decision needs your review."
        case "question-requested": "A task needs your response."
        case "run-failed": "A task needs recovery."
        case "review-ready": "A review is ready."
        case "run-completed": "A task finished."
        default: "An update is available in Kaname."
        }
    }
}

public struct MobileLocalNotificationRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { deliveryID }
    public let deliveryID: String
    public let attentionID: String
    public let streamID: String
    public let dataClass: MobileNotificationDataClass
    public let previewLevel: MobileNotificationPreviewLevel
    public let safePreviewClass: String
    public let deepLinkTarget: String
    public let content: MobileSafeNotificationContent
    public let recordedAtUnixMillis: Int64
}

public enum MobileNotificationSimulationError: Error, Equatable, Sendable {
    case invalidAttention
    case expired
}

/// Network-free notification boundary. It accepts only the deliberately
/// content-free AttentionRecord schema and renders canned previews selected by
/// data-class policy. It never imports UserNotifications or contacts APNs.
public actor LocalMobileNotificationSimulator {
    private var recordsByAttentionID: [String: MobileLocalNotificationRecord] = [:]
    private var orderedAttentionIDs: [String] = []

    public init() {}

    public func simulate(
        attention: Kaname_V1_AttentionRecord,
        dataClass: MobileNotificationDataClass,
        settings: MobileNotificationPrivacySettings,
        nowUnixMillis: Int64
    ) throws -> (MobileLocalNotificationRecord, Kaname_V1_NotificationReceipt) {
        try Self.validate(attention, nowUnixMillis: nowUnixMillis)
        if let existing = recordsByAttentionID[attention.attentionID] {
            return (existing, Self.receipt(for: existing))
        }
        let level = settings.level(for: dataClass)
        let record = MobileLocalNotificationRecord(
            deliveryID: "local-notification-\(orderedAttentionIDs.count + 1)",
            attentionID: attention.attentionID,
            streamID: attention.streamID,
            dataClass: dataClass,
            previewLevel: level,
            safePreviewClass: attention.safePreviewClass,
            deepLinkTarget: attention.deepLinkTarget,
            content: MobileNotificationPreviewRenderer.content(
                level: level,
                dataClass: dataClass,
                safePreviewClass: attention.safePreviewClass
            ),
            recordedAtUnixMillis: nowUnixMillis
        )
        recordsByAttentionID[attention.attentionID] = record
        orderedAttentionIDs.append(attention.attentionID)
        return (record, Self.receipt(for: record))
    }

    public func records() -> [MobileLocalNotificationRecord] {
        orderedAttentionIDs.compactMap { recordsByAttentionID[$0] }
    }

    private static func validate(
        _ attention: Kaname_V1_AttentionRecord,
        nowUnixMillis: Int64
    ) throws {
        guard MobileSyncIdentifier.isValid(attention.attentionID),
              MobileSyncIdentifier.isValid(attention.streamID),
              MobileSyncIdentifier.isValid(attention.kind),
              MobileSyncIdentifier.isValid(attention.safePreviewClass),
              !attention.deepLinkTarget.isEmpty,
              attention.deepLinkTarget.utf8.count <= 512 else {
            throw MobileNotificationSimulationError.invalidAttention
        }
        guard attention.expiresAtUnixMillis >= nowUnixMillis else {
            throw MobileNotificationSimulationError.expired
        }
    }

    private static func receipt(
        for record: MobileLocalNotificationRecord
    ) -> Kaname_V1_NotificationReceipt {
        var receipt = Kaname_V1_NotificationReceipt()
        receipt.attentionID = record.attentionID
        receipt.deliveryID = record.deliveryID
        receipt.state = "simulated_local_only"
        receipt.recordedAtUnixMillis = record.recordedAtUnixMillis
        return receipt
    }
}

private extension MobileNotificationDataClass {
    var safeTitle: String {
        switch self {
        case .publicRepository, .privateRepository: "Repository update"
        case .personalKnowledge: "Knowledge update"
        case .email: "Email update"
        case .calendar: "Calendar update"
        case .providerConversation: "Task update"
        case .deviceSync: "Device update"
        case .audit: "Security update"
        }
    }
}
