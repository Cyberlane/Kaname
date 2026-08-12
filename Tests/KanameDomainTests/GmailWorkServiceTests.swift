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
        #expect(thread.messages.first?.inReplyTo == "")
        #expect(thread.labels == ["INBOX", "UNREAD"])
        #expect(labels.map(\.name) == ["Inbox", "Projects"])
    }

    @Test
    func fullRemoteMessageExposesHeadersAndAttachmentIdentityForOutboundReconciliation() throws {
        let attachment = base64URL("result bytes")
        let message = try GmailAPIParser.message(
            data: Data(
                """
                {"id":"message-2","threadId":"thread-1","labelIds":["SENT"],"payload":{"mimeType":"multipart/mixed","headers":[{"name":"To","value":"Kay <kay@example.test>"},{"name":"Subject","value":"Re: Report"},{"name":"In-Reply-To","value":"<message-1@example.test>"},{"name":"References","value":"<root@example.test> <message-1@example.test>"}],"parts":[{"mimeType":"text/plain","filename":"","body":{"data":"\(base64URL("Attached."))"}},{"mimeType":"application/octet-stream","filename":"result.xlsx","body":{"size":12,"attachmentId":"attachment-2"}}]}}
                """.utf8
            ),
            account: account
        )
        #expect(message.recipients == "Kay <kay@example.test>")
        #expect(message.inReplyTo == "<message-1@example.test>")
        #expect(message.references.contains("<root@example.test>"))
        #expect(message.attachments.first?.messageID == "message-2")
        #expect(GmailAPIParser.normalizedRecipients("B@example.test, a@example.test") == ["a@example.test", "b@example.test"])
        #expect(GmailAPIParser.normalizedRecipients("Kay <kay@example.test>") == ["kay@example.test"])
        #expect(try GmailAPIParser.attachment(data: Data("{\"data\":\"\(attachment)\"}".utf8)) == Data("result bytes".utf8))
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

    @Test
    func historyPagesNormalizeEveryChangeAndPreserveTheAdvanceCursor() throws {
        let page = try GmailAPIParser.historyPage(data: Data(
            """
            {"history":[{"id":"101","messagesAdded":[{"message":{"id":"message-1","threadId":"thread-1","labelIds":["INBOX"]}}],"labelsRemoved":[{"message":{"id":"message-2","threadId":"thread-2"},"labelIds":["UNREAD"]}]}],"nextPageToken":"page-2","historyId":"105"}
            """.utf8
        ))

        #expect(page.latestHistoryID == "105")
        #expect(page.nextPageToken == "page-2")
        #expect(page.events.map(\.kind) == [.messageAdded, .labelsRemoved])
        #expect(page.events.map(\.messageID) == ["message-1", "message-2"])
        #expect(page.events.map(\.labelIDs) == [["INBOX"], ["UNREAD"]])
        #expect(try GmailAPIParser.profileHistoryID(data: Data(#"{"historyId":"105"}"#.utf8)) == "105")
        #expect(throws: GmailWorkError.invalidIdentifier) { _ = try GmailAPIParser.validatedHistoryID("old") }
    }

    @Test
    func outboundReplyIncludesThreadHeadersAndMultipartAttachments() throws {
        let message = GmailOutboundMessage(
            recipients: "recipient@example.test",
            subject: "Re: Review",
            body: "Attached is the corrected result.",
            inReplyTo: "<message-1@example.test>",
            references: ["<root@example.test>"],
            threadID: "thread-1",
            attachments: [GmailOutboundAttachment(
                filename: "result.xlsx",
                mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                data: Data("fictional workbook".utf8)
            )]
        )
        let raw = try GmailAPIParser.rawMessage(message)
        let decoded = try #require(Data(base64URLEncoded: raw))
        let mime = try #require(String(data: decoded, encoding: .utf8))

        #expect(mime.contains("In-Reply-To: <message-1@example.test>"))
        #expect(mime.contains("References: <message-1@example.test> <root@example.test>")
            || mime.contains("References: <root@example.test> <message-1@example.test>"))
        #expect(mime.contains("Content-Type: multipart/mixed"))
        #expect(mime.contains("filename=\"result.xlsx\""))
        #expect(try NativeGoogleIntegrationService.gmailSendTarget(accountID: account.id, message: message)
            != NativeGoogleIntegrationService.gmailSendTarget(
                accountID: account.id,
                message: GmailOutboundMessage(
                    recipients: message.recipients,
                    subject: message.subject,
                    body: message.body,
                    inReplyTo: message.inReplyTo,
                    references: message.references,
                    threadID: message.threadID,
                    attachments: [GmailOutboundAttachment(
                        filename: "result.xlsx",
                        mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                        data: Data("changed workbook".utf8)
                    )]
                )
            ))
    }

    private func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        let translated = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - translated.count % 4) % 4)
        guard let decoded = Data(base64Encoded: translated + padding) else { return nil }
        self = decoded
    }
}
