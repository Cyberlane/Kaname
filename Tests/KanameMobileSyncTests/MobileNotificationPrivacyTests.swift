import Foundation
import KanameMobileSync
import KanameProtocol
import Testing

struct MobileNotificationPrivacyTests {
    private let now: Int64 = 1_786_220_000_000

    @Test
    func privacyPolicyIsConfiguredIndependentlyByDataClass() {
        var settings = MobileNotificationPrivacySettings.privacyFirst
        settings.setLevel(.safeDetail, for: .calendar)
        settings.setLevel(.categoryOnly, for: .privateRepository)

        #expect(settings.level(for: .calendar) == .safeDetail)
        #expect(settings.level(for: .privateRepository) == .categoryOnly)
        #expect(settings.level(for: .email) == .hidden)
    }

    @Test
    func localSimulationUsesOnlyCannedSafeContentAndDeduplicates() async throws {
        let simulator = LocalMobileNotificationSimulator()
        var settings = MobileNotificationPrivacySettings.privacyFirst
        settings.setLevel(.safeDetail, for: .calendar)
        let attention = record(
            id: "attention-calendar-1",
            previewClass: "approval-required"
        )

        let first = try await simulator.simulate(
            attention: attention,
            dataClass: .calendar,
            settings: settings,
            nowUnixMillis: now
        )
        let duplicate = try await simulator.simulate(
            attention: attention,
            dataClass: .calendar,
            settings: settings,
            nowUnixMillis: now + 1
        )

        #expect(first.0.content.title == "Calendar update")
        #expect(first.0.content.body == "A decision needs your review.")
        #expect(first.1.state == "simulated_local_only")
        #expect(duplicate.0.deliveryID == first.0.deliveryID)
        #expect(await simulator.records().count == 1)
        let encoded = try JSONEncoder().encode(first.0)
        #expect(!encoded.contains(Data("Reschedule dental appointment".utf8)))
        #expect(!encoded.contains(Data("private calendar body".utf8)))
    }

    @Test
    func hiddenAndCategoryPoliciesDoNotRevealThePreviewClass() async throws {
        let simulator = LocalMobileNotificationSimulator()
        let hidden = try await simulator.simulate(
            attention: record(id: "attention-email-1", previewClass: "run-failed"),
            dataClass: .email,
            settings: .privacyFirst,
            nowUnixMillis: now
        ).0
        var categorySettings = MobileNotificationPrivacySettings.privacyFirst
        categorySettings.setLevel(.categoryOnly, for: .privateRepository)
        let category = try await simulator.simulate(
            attention: record(id: "attention-repo-1", previewClass: "run-failed"),
            dataClass: .privateRepository,
            settings: categorySettings,
            nowUnixMillis: now
        ).0

        #expect(hidden.content == MobileSafeNotificationContent(
            title: "Kaname",
            body: "Open Kaname to view this update."
        ))
        #expect(category.content == MobileSafeNotificationContent(
            title: "Repository update",
            body: "Attention is available in Kaname."
        ))
    }

    @Test
    func expiredAttentionCannotCreateALocalDeliveryRecord() async {
        let simulator = LocalMobileNotificationSimulator()

        await #expect(throws: MobileNotificationSimulationError.expired) {
            try await simulator.simulate(
                attention: record(
                    id: "attention-expired-1",
                    previewClass: "approval-required",
                    expiresAt: now - 1
                ),
                dataClass: .calendar,
                settings: .privacyFirst,
                nowUnixMillis: now
            )
        }
        #expect(await simulator.records().isEmpty)
    }

    private func record(
        id: String,
        previewClass: String,
        expiresAt: Int64? = nil
    ) -> Kaname_V1_AttentionRecord {
        var attention = Kaname_V1_AttentionRecord()
        attention.attentionID = id
        attention.streamID = "thread-phase3"
        attention.kind = "approval.required"
        attention.safePreviewClass = previewClass
        attention.deepLinkTarget = "kaname://work/attention/\(id)"
        attention.expiresAtUnixMillis = expiresAt ?? now + 60_000
        return attention
    }
}
