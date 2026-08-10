import Foundation
import Testing
@testable import KanameConnectivity

struct GmailWorkServiceTests {
    private let account = NativeGoogleAccountSnapshot(
        id: "account-1",
        identity: "one@example.test",
        displayName: "One",
        capabilities: ["Gmail"]
    )

    @Test
    func paginationThreadBodiesAttachmentsAndLabelsPreserveAccountIdentity() throws {
        let page = try GmailAPIParser.threadPage(data: Data(
            #"{"threads":[{"id":"thread-1"},{"id":"thread-2"}],"nextPageToken":"next-2"}"#.utf8
        ))
        let plain = base64URL("Hello from the complete message body.")
        let thread = try GmailAPIParser.thread(
            data: Data(
                """
                {"id":"thread-1","snippet":"Hello","historyId":"99","messages":[{"id":"message-1","threadId":"thread-1","labelIds":["INBOX","UNREAD"],"payload":{"mimeType":"multipart/mixed","headers":[{"name":"From","value":"Sender <sender@example.test>"},{"name":"To","value":"one@example.test"},{"name":"Subject","value":"Complete thread"},{"name":"Date","value":"Today"}],"parts":[{"mimeType":"text/plain","filename":"","body":{"size":38,"data":"\(plain)"}},{"mimeType":"application/pdf","filename":"report.pdf","body":{"size":1200,"attachmentId":"attachment-1"}}]}}]}
                """.utf8
            ),
            account: account
        )
        let labels = try GmailAPIParser.labels(data: Data(
            #"{"labels":[{"id":"INBOX","name":"Inbox","type":"system"},{"id":"Label_1","name":"Projects","type":"user"}]}"#.utf8
        ))

        #expect(page.ids == ["thread-1", "thread-2"])
        #expect(page.nextPageToken == "next-2")
        #expect(thread.accountID == account.id)
        #expect(thread.accountIdentity == account.identity)
        #expect(thread.messages.first?.body == "Hello from the complete message body.")
        #expect(thread.messages.first?.attachments.first?.filename == "report.pdf")
        #expect(thread.labels == ["INBOX", "UNREAD"])
        #expect(labels.map(\.name) == ["Inbox", "Projects"])
    }

    @Test
    func exactMutationAndOutboundTargetsBindAccountThreadActionAndContent() throws {
        let archive = NativeGoogleIntegrationService.gmailMutationTarget(
            accountID: account.id,
            threadID: "thread-1",
            mutation: .archive
        )
        let message = GmailOutboundMessage(
            recipients: "recipient@example.test",
            subject: "Subject",
            body: "Body"
        )
        let send = try NativeGoogleIntegrationService.gmailSendTarget(accountID: account.id, message: message)
        let changed = try NativeGoogleIntegrationService.gmailSendTarget(
            accountID: account.id,
            message: GmailOutboundMessage(recipients: message.recipients, subject: message.subject, body: "Changed")
        )

        #expect(archive == "gmail:account-1:thread:thread-1:archive")
        #expect(send.hasPrefix("gmail:account-1:send:sha256="))
        #expect(send != changed)
        #expect(GmailAPIParser.reconciled(mutation: .archive, labels: ["STARRED"]))
        #expect(!GmailAPIParser.reconciled(mutation: .archive, labels: ["INBOX"]))
        #expect(GmailAPIParser.reconciled(
            mutation: .applyLabels(add: ["Label_1"], remove: ["INBOX"]),
            labels: ["Label_1"]
        ))
    }

    @Test
    func rawMessageRejectsHeaderInjectionAndAttachmentDecoderIsBoundedData() throws {
        #expect(throws: GmailWorkError.invalidMessage) {
            _ = try NativeGoogleIntegrationService.gmailSendTarget(
                accountID: account.id,
                message: GmailOutboundMessage(
                    recipients: "person@example.test\nBcc: hidden@example.test",
                    subject: "Subject",
                    body: "Body"
                )
            )
        }
        let payload = base64URL("attachment bytes")
        #expect(try GmailAPIParser.attachment(data: Data("{\"data\":\"\(payload)\"}".utf8)) == Data("attachment bytes".utf8))
        #expect(throws: GmailWorkError.invalidIdentifier) { _ = try GmailAPIParser.validatedID("../thread") }
    }

    @Test
    func multipartAlternativePrefersPlainTextWithoutDuplicatingTheMessage() throws {
        let plain = base64URL("Readable plain text")
        let html = base64URL("<p>Readable HTML</p>")
        let thread = try GmailAPIParser.thread(
            data: Data(
                """
                {"id":"thread-1","messages":[{"id":"message-1","threadId":"thread-1","payload":{"mimeType":"multipart/alternative","parts":[{"mimeType":"text/plain","filename":"","body":{"data":"\(plain)"}},{"mimeType":"text/html","filename":"","body":{"data":"\(html)"}}]}}]}
                """.utf8
            ),
            account: account
        )

        #expect(thread.messages.first?.body == "Readable plain text")
    }

    private func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
