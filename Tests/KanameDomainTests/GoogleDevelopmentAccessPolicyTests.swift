import Foundation
import Testing
@testable import KanameConnectivity

struct GoogleDevelopmentAccessPolicyTests {
    @Test
    func developmentEnvironmentRequestsReadOnlyScopesAndDisablesExecution() async {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-google-policy-\(UUID().uuidString)", isDirectory: true)
        let development = KanameDesktopEnvironment(channel: .development, applicationSupportDirectory: base)
        let stable = KanameDesktopEnvironment(channel: .stable, applicationSupportDirectory: base)
        let service = NativeGoogleIntegrationService(
            rootDirectory: development.googleDirectory,
            keychainService: "com.cyberlane.kaname.tests.read-only.\(UUID().uuidString)",
            accessMode: development.googleIntegrationAccessMode
        )

        let scopes = await service.authorizationScopes
        #expect(development.externalMutationPolicy == .denied)
        #expect(!development.allowsExternalMutations)
        #expect(!development.allowsAutomaticExecution)
        #expect(development.googleIntegrationAccessMode == .readOnly)
        #expect(stable.externalMutationPolicy == .allowed)
        #expect(stable.allowsExternalMutations)
        #expect(stable.allowsAutomaticExecution)
        #expect(scopes.contains("https://www.googleapis.com/auth/gmail.readonly"))
        #expect(scopes.contains("https://www.googleapis.com/auth/calendar.readonly"))
        #expect(!scopes.contains("https://www.googleapis.com/auth/gmail.modify"))
        #expect(!scopes.contains("https://www.googleapis.com/auth/gmail.compose"))
        #expect(!scopes.contains("https://www.googleapis.com/auth/calendar.events"))
    }

    @Test
    func readOnlyGoogleServiceRejectsEveryMutationBeforeAccountOrNetworkAccess() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-google-denial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = NativeGoogleIntegrationService(
            rootDirectory: root,
            keychainService: "com.cyberlane.kaname.tests.denied.\(UUID().uuidString)",
            accessMode: .readOnly
        )
        let mutationGrant = GmailMutationGrant(
            approvalID: "approval",
            exactTarget: NativeGoogleIntegrationService.gmailMutationTarget(
                accountID: "missing-account",
                threadID: "thread-1",
                mutation: .archive
            )
        )
        await #expect(throws: NativeGoogleIntegrationError.mutationDeniedByAccessPolicy) {
            try await service.mutateMailThread(
                accountID: "missing-account",
                threadID: "thread-1",
                mutation: .archive,
                grant: mutationGrant
            )
        }
        await #expect(throws: NativeGoogleIntegrationError.mutationDeniedByAccessPolicy) {
            try await service.createGmailDraft(
                accountID: "missing-account",
                message: GmailOutboundMessage(
                    recipients: "person@example.test",
                    subject: "Local draft",
                    body: "Do not send"
                ),
                grant: GmailMutationGrant(approvalID: "approval", exactTarget: "not-dispatched")
            )
        }
        await #expect(throws: NativeGoogleIntegrationError.mutationDeniedByAccessPolicy) {
            try await service.mutateGoogleCalendar(
                accountID: "missing-account",
                calendarID: "primary",
                mutation: .create(.timed(
                    title: "Local event",
                    startAtUnixMillis: 1_000,
                    endAtUnixMillis: 2_000,
                    timeZoneIdentifier: "UTC",
                    recurrence: "Does not repeat"
                )),
                grant: .approved(
                    operationID: "operation",
                    approvalID: "approval",
                    exactTarget: "not-dispatched"
                )
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
