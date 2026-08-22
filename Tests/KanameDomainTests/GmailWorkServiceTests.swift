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
    func metadataParserProjectsOnlySelectedHeadersLabelsAndCursor() throws {
        let metadata = try GmailAPIParser.threadMetadata(
            data: Data(
                """
                {"id":"thread-1","historyId":"105","messages":[{"id":"message-1","threadId":"thread-1","labelIds":["UNREAD","INBOX"],"snippet":"excluded body-like text","payload":{"mimeType":"multipart/mixed","headers":[{"name":"From","value":"sender@example.test"},{"name":"Date","value":"Today"},{"name":"Subject","value":"Excluded subject"}],"body":{"data":"ZXhjbHVkZWQgYm9keQ=="},"parts":[{"filename":"excluded.pdf","body":{"attachmentId":"excluded-attachment"}}]}}]}
                """.utf8
            ),
            account: account,
            selectedHeaders: ["From", "from", "Date"]
        )

        #expect(metadata.historyID == "105")
        #expect(metadata.messages.first?.headers == [
            "Date": "Today", "From": "sender@example.test",
        ])
        #expect(metadata.messages.first?.labels == ["INBOX", "UNREAD"])
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
        let html = base64URL("<p>Readable <strong>HTML</strong></p>")
        let thread = try GmailAPIParser.thread(
            data: Data(
                """
                {"id":"thread-1","messages":[{"id":"message-1","threadId":"thread-1","payload":{"mimeType":"multipart/alternative","parts":[{"mimeType":"text/plain","filename":"","body":{"data":"\(plain)"}},{"mimeType":"text/html","filename":"","body":{"data":"\(html)"}}]}}]}
                """.utf8
            ),
            account: account
        )

        #expect(thread.messages.first?.body == "Readable plain text")
        #expect(thread.messages.first?.readerMarkdown?.contains("Readable **HTML**") == true)
        #expect(thread.messages.first?.htmlBody?.contains("<strong>HTML</strong>") == true)
        #expect(thread.messages.first?.sanitizedHTML?.contains("<strong>HTML</strong>") == true)
    }

    @Test
    func htmlOnlyMessageSeparatesReaderContentFromBoundedOriginalHTML() throws {
        let html = """
        <html>
          <head>
            <style>@media screen { .button { font-family: sans-serif; color: red; } }</style>
          </head>
          <body>
            <div style="display: none">Inbox preview that should stay hidden</div>
            <h1>How did we do?</h1>
            <p>Tell us about your transfer.</p>
            <a href="https://example.test/feedback">Share feedback</a>
            <img src="https://images.example.test/survey.png?recipient=unique" width="600" height="240" alt="Survey illustration">
            <img src="http://images.example.test/app-store.png?recipient=unique" width="160" height="48" alt="Download the app">
          </body>
        </html>
        """
        let thread = try GmailAPIParser.thread(
            data: Data(
                """
                {"id":"thread-1","messages":[{"id":"message-1","threadId":"thread-1","payload":{"mimeType":"text/html","filename":"","body":{"data":"\(base64URL(html))"}}}]}
                """.utf8
            ),
            account: account
        )
        let message = try #require(thread.messages.first)

        #expect(message.body.contains("How did we do?"))
        #expect(message.body.contains("Tell us about your transfer."))
        #expect(!message.body.contains("@media"))
        #expect(!message.body.contains("font-family"))
        #expect(!message.body.contains("Inbox preview"))
        #expect(message.readerMarkdown?.contains("# How did we do?") == true)
        #expect(message.readerMarkdown?.contains("[Share feedback](<https://example.test/feedback>)") == true)
        #expect(message.htmlBody?.contains("@media screen") == true)
        #expect(message.sanitizedHTML?.contains("How did we do?") == true)
        #expect(message.sanitizedHTML?.contains("Content-Security-Policy") == true)
        #expect(message.sanitizedHTML?.contains("@media screen") == false)
        #expect(message.sanitizedHTML?.contains("images.example.test") == false)
        #expect(message.sanitizedHTML?.contains("[Image: Survey illustration]") == true)
        #expect(message.sanitizedHTML?.contains("[Image: Download the app]") == true)
        #expect(message.directRemoteImagesHTML?.contains("https://images.example.test/survey.png?recipient=unique") == true)
        #expect(message.directRemoteImagesHTML?.contains("https://images.example.test/app-store.png?recipient=unique") == true)
        #expect(message.directRemoteImagesHTML?.contains("http://") == false)
        #expect(message.remoteImageCount == 2)
        #expect(message.insecureRemoteImageCount == 1)
    }

    @Test
    func nestedAlternativeHonorsDeclaredLegacyCharsetForSemanticText() throws {
        let latin1 = Data([0x43, 0x72, 0xe8, 0x6d, 0x65])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let html = base64URL("<h2>Crème HTML</h2>")
        let thread = try GmailAPIParser.thread(
            data: Data(
                """
                {"id":"thread-1","messages":[{"id":"message-1","threadId":"thread-1","payload":{"mimeType":"multipart/mixed","parts":[{"mimeType":"multipart/alternative","parts":[{"mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=iso-8859-1"}],"body":{"data":"\(latin1)"}},{"mimeType":"text/html","filename":"","body":{"data":"\(html)"}}]},{"mimeType":"application/pdf","filename":"report.pdf","body":{"size":1200,"attachmentId":"attachment-1"}}]}}]}
                """.utf8
            ),
            account: account
        )
        let message = try #require(thread.messages.first)

        #expect(message.body == "Crème")
        #expect(message.readerMarkdown?.contains("## Crème HTML") == true)
        #expect(message.attachments.map(\.filename) == ["report.pdf"])
    }

    @Test
    func externalTextBodyReferencesAreFetchedSeparatelyAndRemainBounded() throws {
        let htmlData = Data("<p>Externally stored <strong>HTML body</strong>.</p>".utf8)
        let wire = Data(
            """
            {"id":"thread-1","messages":[{"id":"message-1","threadId":"thread-1","payload":{"mimeType":"text/html","filename":"","body":{"size":\(htmlData.count),"attachmentId":"body-attachment-1"}}}]}
            """.utf8
        )
        let references = try GmailAPIParser.externalBodyReferences(data: wire)
        let reference = try #require(references.first)
        let thread = try GmailAPIParser.thread(
            data: wire,
            account: account,
            externalBodyData: [reference: htmlData]
        )

        #expect(references.count == 1)
        #expect(reference.messageID == "message-1")
        #expect(reference.attachmentID == "body-attachment-1")
        #expect(thread.messages.first?.body == "Externally stored HTML body.")
        #expect(thread.messages.first?.readerMarkdown?.contains("Externally stored **HTML body**.") == true)
        #expect(thread.messages.first?.sanitizedHTML?.contains("<strong>HTML body</strong>") == true)
    }

    @Test
    func inlineCIDImageBytesRenderLocallyWithoutARemoteImageVariant() throws {
        let png = try #require(Data(base64Encoded: Self.twoByTwoPNGBase64))
        let html = base64URL("<p>Chart follows</p><img src=\"cid:chart%40example.test\" alt=\"Account chart\">")
        let image = base64URL(png)
        let thread = try GmailAPIParser.thread(
            data: Data(
                """
                {"id":"thread-1","messages":[{"id":"message-1","threadId":"thread-1","payload":{"mimeType":"multipart/related","parts":[{"mimeType":"text/html","filename":"","body":{"data":"\(html)"}},{"mimeType":"image/png","filename":"chart.png","headers":[{"name":"Content-ID","value":"<Chart@example.test>"},{"name":"Content-Disposition","value":"inline"}],"body":{"size":\(png.count),"data":"\(image)"}}]}}]}
                """.utf8
            ),
            account: account
        )
        let message = try #require(thread.messages.first)
        let sanitizedHTML = try #require(message.sanitizedHTML)

        #expect(message.embeddedImageCount == 1)
        #expect(message.remoteImageCount == 0)
        #expect(message.insecureRemoteImageCount == 0)
        #expect(message.directRemoteImagesHTML == nil)
        #expect(sanitizedHTML.contains("src=\"data:image/png;base64,"))
        #expect(!sanitizedHTML.contains("cid:"))
        #expect(sanitizedHTML.contains("img-src data:"))
    }

    @Test
    func externalCIDImageReferencesAreBoundedAndResolvedPerMessage() throws {
        let png = try #require(Data(base64Encoded: Self.twoByTwoPNGBase64))
        let html = base64URL("<p>External chart</p><img src=\"cid:chart-2\" alt=\"External chart\">")
        let wire = Data(
            """
            {"id":"thread-1","messages":[{"id":"message-1","threadId":"thread-1","payload":{"mimeType":"multipart/related","parts":[{"mimeType":"text/html","filename":"","body":{"data":"\(html)"}},{"mimeType":"image/png","filename":"chart.png","headers":[{"name":"Content-ID","value":"<chart-2>"},{"name":"Content-Disposition","value":"inline"}],"body":{"size":\(png.count),"attachmentId":"inline-attachment-1"}},{"mimeType":"image/png","filename":"unused.png","headers":[{"name":"Content-ID","value":"<unused>"},{"name":"Content-Disposition","value":"inline"}],"body":{"size":\(png.count),"attachmentId":"inline-attachment-2"}}]}}]}
            """.utf8
        )
        let references = try GmailAPIParser.externalInlineImageReferences(data: wire)
        let reference = try #require(references.first)
        let thread = try GmailAPIParser.thread(
            data: wire,
            account: account,
            externalBodyData: [:],
            externalInlineImageData: [reference: png]
        )
        let message = try #require(thread.messages.first)

        #expect(references.count == 1)
        #expect(reference.contentID == "chart-2")
        #expect(reference.mimeType == "image/png")
        #expect(reference.expectedSize == png.count)
        #expect(message.embeddedImageCount == 1)
        #expect(message.sanitizedHTML?.contains("src=\"data:image/png;base64,") == true)
        #expect(message.attachments.map(\.filename) == ["chart.png", "unused.png"])
    }

    @Test
    func htmlReaderFailureFallsBackToTheGmailMessageSnippet() throws {
        let openingTags = String(repeating: "<div>", count: MailHTMLReader.maximumTreeDepth + 10)
        let closingTags = String(repeating: "</div>", count: MailHTMLReader.maximumTreeDepth + 10)
        let html = openingTags + "Full body beyond the reader depth limit" + closingTags
        let thread = try GmailAPIParser.thread(
            data: Data(
                """
                {"id":"thread-1","messages":[{"id":"message-1","threadId":"thread-1","snippet":"Gmail preview remains readable","payload":{"mimeType":"text/html","filename":"","body":{"data":"\(base64URL(html))"}}}]}
                """.utf8
            ),
            account: account
        )
        let message = try #require(thread.messages.first)

        #expect(message.body == "Gmail preview remains readable")
        #expect(message.sanitizedHTML == nil)
        #expect(message.htmlBody?.contains("Full body beyond the reader depth limit") == true)
        #expect(message.bodyDisplayNotice?.contains("Gmail's text preview") == true)
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
        base64URL(Data(value.utf8))
    }

    private func base64URL(_ value: Data) -> String {
        value.base64URLEncodedString()
    }

    private static let twoByTwoPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAD0lEQVR4nGP4z8DAwMAAAAYIAQHLR3Z1AAAAAElFTkSuQmCC"
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
