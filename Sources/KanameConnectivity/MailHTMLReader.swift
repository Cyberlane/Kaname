import Foundation
import ImageIO
import SwiftSoup

struct MailHTMLEmbeddedImage: Equatable, Sendable {
    let mimeType: String
    let data: Data
}

struct MailHTMLReaderDocument: Equatable, Sendable {
    let sourceHTML: String
    /// A complete, inert HTML document suitable for the mail viewer. Sender scripts,
    /// forms, remote resources, unsafe CSS, and unsupported markup are removed.
    let sanitizedHTML: String?
    /// A separately sanitized document that permits only validated HTTPS image
    /// subresources. It must be shown only after an explicit direct-load action.
    let directRemoteImagesHTML: String?
    let remoteImageCount: Int
    let insecureRemoteImageCount: Int
    let embeddedImageCount: Int
    let markdown: String
    let plainText: String
    let sourceWasTruncated: Bool
}

enum MailHTMLReader {
    static let maximumInputBytes = 2_000_000
    static let maximumNodeCount = 50_000
    static let maximumTreeDepth = 256
    static let maximumOutputBytes = 300_000
    static let maximumSanitizedHTMLBytes = 10_500_000
    static let maximumEmbeddedImageBytes = 4_000_000
    static let maximumEmbeddedImagePixels: Int64 = 50_000_000
    static let maximumEmbeddedImageDimension = 12_000

    static func render(
        _ html: String,
        embeddedImages: [String: MailHTMLEmbeddedImage] = [:]
    ) -> MailHTMLReaderDocument? {
        let sourceWasTruncated = html.utf8.count > maximumInputBytes
        let sourceHTML = String(decoding: html.utf8.prefix(maximumInputBytes), as: UTF8.self)

        do {
            let document = try SwiftSoup.parse(sourceHTML)
            try removeNonContent(from: document)
            let root: Node = document.body() ?? document
            let markdown = try MailHTMLReaderVisitor(mode: .markdown).render(root)
            let plainText = try MailHTMLReaderVisitor(mode: .plainText).render(root)
            let notice = "Message content was truncated for safe display."
            let renderedMarkdown = appendNotice(notice, to: markdown, when: sourceWasTruncated)
            let renderedPlainText = appendNotice(notice, to: plainText, when: sourceWasTruncated)
            guard !renderedMarkdown.isEmpty || !renderedPlainText.isEmpty else { return nil }
            let blockedDisplay = try? sanitizedDocument(
                from: document,
                embeddedImages: embeddedImages,
                allowsRemoteImages: false
            )
            let directDisplay: SanitizedDocument?
            if (blockedDisplay?.remoteImageCount ?? 0) > 0 {
                directDisplay = try? sanitizedDocument(
                    from: document,
                    embeddedImages: embeddedImages,
                    allowsRemoteImages: true
                )
            } else {
                directDisplay = nil
            }
            return MailHTMLReaderDocument(
                sourceHTML: sourceHTML,
                sanitizedHTML: blockedDisplay?.html,
                directRemoteImagesHTML: directDisplay?.html,
                remoteImageCount: blockedDisplay?.remoteImageCount ?? 0,
                insecureRemoteImageCount: blockedDisplay?.insecureRemoteImageCount ?? 0,
                embeddedImageCount: blockedDisplay?.embeddedImageCount ?? 0,
                markdown: renderedMarkdown,
                plainText: renderedPlainText,
                sourceWasTruncated: sourceWasTruncated
            )
        } catch {
            return nil
        }
    }

    static func markdown(fromPlainText text: String) -> String {
        escapedMarkdownText(boundedOutput(text))
    }

    static func boundedPlainText(_ text: String) -> String {
        boundedOutput(
            text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\0", with: "")
        )
    }

    fileprivate static func escapedMarkdownText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: ">", with: "\\>")
    }

    fileprivate static func safeLinkDestination(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 8_192,
              !value.contains("<"),
              !value.contains(">"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" {
            guard components.host?.isEmpty == false else { return nil }
        } else {
            guard !components.path.isEmpty else { return nil }
        }
        return components.url?.absoluteString
    }

    static func normalizedContentID(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cid:") {
            value.removeFirst(4)
        }
        value = value.removingPercentEncoding ?? value
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), value.hasSuffix(">"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains(where: \Character.isWhitespace) else { return nil }
        return value.lowercased()
    }

    static func referencedContentIDs(in html: String) -> Set<String> {
        let boundedHTML = String(decoding: html.utf8.prefix(maximumInputBytes), as: UTF8.self)
        guard let document = try? SwiftSoup.parse(boundedHTML),
              let images = try? document.select("img[src]") else { return [] }
        return Set(images.compactMap { image in
            guard let source = try? image.attr("src"),
                  source.lowercased().hasPrefix("cid:") else { return nil }
            return normalizedContentID(source)
        })
    }

    private static func removeNonContent(from document: Document) throws {
        try document.select(
            "head, style, script, noscript, template, iframe, object, embed, svg, canvas, audio, video, source"
        ).remove()
        try document.select("[hidden], .preheader, #preheader").remove()

        for element in try document.select("[aria-hidden]") {
            if try element.attr("aria-hidden")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("true") == .orderedSame {
                try element.remove()
            }
        }

        for element in try document.select("[style]") {
            let style = try element.attr("style")
                .lowercased()
                .filter { !$0.isWhitespace }
            let hidden = style.contains("display:none")
                || style.contains("visibility:hidden")
                || style.contains("mso-hide:all")
                || hasZeroOpacity(style)
                || (style.contains("max-height:0") && style.contains("overflow:hidden"))
            if hidden { try element.remove() }
        }

        for image in try document.select("img") {
            let width = Int(try image.attr("width").trimmingCharacters(in: .whitespacesAndNewlines))
            let height = Int(try image.attr("height").trimmingCharacters(in: .whitespacesAndNewlines))
            if (width.map { $0 <= 1 } ?? false) && (height.map { $0 <= 1 } ?? false) {
                try image.remove()
            }
        }
    }

    private static func hasZeroOpacity(_ normalizedStyle: String) -> Bool {
        normalizedStyle.split(separator: ";").contains { declaration in
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0] == "opacity" else { return false }
            let value = pair[1].replacingOccurrences(of: "!important", with: "")
            return Double(value) == 0
        }
    }

    private struct SanitizedDocument {
        let html: String
        let remoteImageCount: Int
        let insecureRemoteImageCount: Int
        let embeddedImageCount: Int
    }

    private struct RemoteImageSource {
        let directURL: String
        let requiredHTTPSUpgrade: Bool
    }

    private static func sanitizedDocument(
        from document: Document,
        embeddedImages: [String: MailHTMLEmbeddedImage],
        allowsRemoteImages: Bool
    ) throws -> SanitizedDocument? {
        guard let body = document.body() else { return nil }
        let displayDocument = try SwiftSoup.parseBodyFragment(try body.html())
        var remoteImageCount = 0
        var insecureRemoteImageCount = 0
        var embeddedImageCount = 0

        for image in try displayDocument.select("img") {
            let source = try image.attr("src")
            if let contentID = normalizedContentID(source),
               source.lowercased().hasPrefix("cid:"),
               let resource = embeddedImages[contentID],
               let dataURL = validatedDataURL(for: resource) {
                try image.attr("src", dataURL)
                try image.removeAttr("srcset")
                try image.attr("referrerpolicy", "no-referrer")
                embeddedImageCount += 1
                continue
            }

            if let remoteSource = remoteImageSource(source) {
                remoteImageCount += 1
                if remoteSource.requiredHTTPSUpgrade {
                    insecureRemoteImageCount += 1
                }
                if allowsRemoteImages {
                    try image.attr("src", remoteSource.directURL)
                    try image.removeAttr("srcset")
                    try image.attr("referrerpolicy", "no-referrer")
                    continue
                }
            }

            try replaceImageWithAltText(image)
        }

        let whitelist = try displayWhitelist()
        guard let dirtyBody = displayDocument.body(),
              let sanitizedBody = try SwiftSoup.clean(try dirtyBody.html(), "", whitelist),
              !sanitizedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let imageSources = allowsRemoteImages ? "data: https:" : "data:"
        let rendered = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <meta name="referrer" content="no-referrer">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src \(imageSources); font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; style-src 'unsafe-inline'">
          <style>
            :root { color-scheme: light; }
            html, body { margin: 0; padding: 0; background: #ffffff; color: #20242b; }
            body { padding: 16px; box-sizing: border-box; overflow-wrap: anywhere; -webkit-text-size-adjust: 100%; }
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; font-size: 15px; line-height: 1.45; }
            table { max-width: 100% !important; }
            td, th { overflow-wrap: anywhere; }
            a { color: #2563a6; }
            pre { white-space: pre-wrap; overflow-wrap: anywhere; }
          </style>
        </head>
        <body>\(sanitizedBody)</body>
        </html>
        """
        guard rendered.utf8.count <= maximumSanitizedHTMLBytes else { return nil }
        return SanitizedDocument(
            html: rendered,
            remoteImageCount: remoteImageCount,
            insecureRemoteImageCount: insecureRemoteImageCount,
            embeddedImageCount: embeddedImageCount
        )
    }

    private static func displayWhitelist() throws -> Whitelist {
        let whitelist = try Whitelist.relaxed()
            .removeProtocols("a", "href", "ftp")
            .addTags("article", "section", "main", "header", "footer", "address", "center", "font")
            .addAttributes(":all", "dir", "lang", "role", "aria-label", "style")
            .addAttributes("a", "href", "title")
            .addAttributes("font", "color", "face", "size")
            .addAttributes("img", "alt", "height", "src", "title", "width", "referrerpolicy")
            .addProtocols("img", "src", "data")
            .addEnforcedAttribute("img", "referrerpolicy", "no-referrer")
            .addAttributes("table", "align", "bgcolor", "border", "cellpadding", "cellspacing", "height", "width")
            .addAttributes("tbody", "align", "valign")
            .addAttributes("thead", "align", "valign")
            .addAttributes("tfoot", "align", "valign")
            .addAttributes("tr", "align", "bgcolor", "height", "valign")
            .addAttributes("td", "align", "bgcolor", "height", "valign")
            .addAttributes("th", "align", "bgcolor", "height", "valign")
            .addEnforcedAttribute("a", "rel", "nofollow noopener noreferrer")
            .urlWhitespace(.trim)

        return try whitelist.addCSSProperties(
            ":all",
            "-webkit-text-size-adjust",
            "background", "background-color",
            "border", "border-bottom", "border-bottom-color", "border-bottom-style", "border-bottom-width",
            "border-collapse", "border-color", "border-left", "border-left-color", "border-left-style",
            "border-left-width", "border-radius", "border-right", "border-right-color", "border-right-style",
            "border-right-width", "border-spacing", "border-style", "border-top", "border-top-color",
            "border-top-style", "border-top-width", "border-width",
            "box-sizing", "clear", "color", "direction", "display", "float",
            "font", "font-family", "font-size", "font-style", "font-variant", "font-weight",
            "height", "letter-spacing", "line-height",
            "margin", "margin-bottom", "margin-left", "margin-right", "margin-top",
            "max-height", "max-width", "min-height", "min-width", "overflow", "overflow-wrap",
            "padding", "padding-bottom", "padding-left", "padding-right", "padding-top",
            "table-layout", "text-align", "text-decoration", "text-transform",
            "vertical-align", "white-space", "width", "word-break", "word-spacing"
        )
    }

    private static func replaceImageWithAltText(_ image: Element) throws {
        let alt = try image.attr("alt").trimmingCharacters(in: .whitespacesAndNewlines)
        if alt.isEmpty {
            try image.remove()
        } else {
            try image.replaceWith(TextNode("[Image: \(String(alt.prefix(512)))]", ""))
        }
    }

    private static func remoteImageSource(_ rawValue: String) -> RemoteImageSource? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 8_192,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty,
              !isObviouslyLocalHost(host) else { return nil }

        let requiredHTTPSUpgrade = scheme == "http"
        if requiredHTTPSUpgrade {
            guard components.port == nil || components.port == 80 else { return nil }
            components.scheme = "https"
            components.port = nil
        } else {
            guard components.port == nil || components.port == 443 else { return nil }
        }
        guard let directURL = components.url?.absoluteString else { return nil }
        return RemoteImageSource(
            directURL: directURL,
            requiredHTTPSUpgrade: requiredHTTPSUpgrade
        )
    }

    private static func isObviouslyLocalHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalizedHost == "localhost" || normalizedHost.hasSuffix(".localhost")
            || normalizedHost.hasSuffix(".local") || normalizedHost.hasSuffix(".internal")
            || normalizedHost.hasSuffix(".lan") || normalizedHost.contains(":") {
            return true
        }
        let pieces = normalizedHost.split(separator: ".", omittingEmptySubsequences: false)
        if (1 ... 4).contains(pieces.count), pieces.allSatisfy(isLegacyIPv4Component) {
            return true
        }
        return false
    }

    private static func isLegacyIPv4Component(_ component: Substring) -> Bool {
        let value = component.lowercased()
        if value.hasPrefix("0x") {
            let digits = value.dropFirst(2)
            return !digits.isEmpty && digits.utf8.allSatisfy {
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            }
        }
        return !value.isEmpty && value.utf8.allSatisfy { (48 ... 57).contains($0) }
    }

    private static func validatedDataURL(for resource: MailHTMLEmbeddedImage) -> String? {
        let declaredMIMEType = normalizedImageMIMEType(resource.mimeType)
        guard resource.data.count <= maximumEmbeddedImageBytes,
              let declaredMIMEType,
              detectedImageMIMEType(resource.data) == declaredMIMEType,
              let source = CGImageSourceCreateWithData(resource.data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maximumEmbeddedImageDimension,
              height <= maximumEmbeddedImageDimension,
              Int64(width) * Int64(height) <= maximumEmbeddedImagePixels,
              !(width <= 1 && height <= 1) else { return nil }
        return "data:\(declaredMIMEType);base64,\(resource.data.base64EncodedString())"
    }

    private static func normalizedImageMIMEType(_ rawValue: String) -> String? {
        let value = rawValue.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return switch value {
        case "image/jpeg", "image/jpg": "image/jpeg"
        case "image/png": "image/png"
        case "image/gif": "image/gif"
        case "image/webp": "image/webp"
        default: nil
        }
    }

    private static func detectedImageMIMEType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
            return "image/png"
        }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) {
            return "image/jpeg"
        }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
            return "image/gif"
        }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return "image/webp"
        }
        return nil
    }

    private static func appendNotice(_ notice: String, to text: String, when required: Bool) -> String {
        guard required else { return text }
        return text.isEmpty ? notice : "\(text)\n\n\(notice)"
    }

    private static func boundedOutput(_ text: String) -> String {
        guard text.utf8.count > maximumOutputBytes else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bounded = String(decoding: text.utf8.prefix(maximumOutputBytes), as: UTF8.self)
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\nMessage text was truncated for safe display."
    }
}

private final class MailHTMLReaderVisitor: NodeVisitor {
    enum Mode {
        case markdown
        case plainText
    }

    private enum ReaderError: Error {
        case resourceLimit
    }

    private let mode: Mode
    private var output = ""
    private var nodeCount = 0
    private var pendingSpace = false
    private var preformattedDepth = 0
    private var links: [ObjectIdentifier: (start: Int, destination: String)] = [:]

    init(mode: Mode) {
        self.mode = mode
    }

    func render(_ root: Node) throws -> String {
        try NodeTraversor(self).traverse(root)
        return boundedResult(output)
    }

    func head(_ node: Node, _ depth: Int) throws {
        nodeCount += 1
        guard nodeCount <= MailHTMLReader.maximumNodeCount,
              depth <= MailHTMLReader.maximumTreeDepth else { throw ReaderError.resourceLimit }

        if let textNode = node as? TextNode {
            appendText(textNode.getWholeText(), preformatted: preformattedDepth > 0)
            return
        }
        guard let element = node as? Element else { return }

        let tag = element.tagNameNormal()
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            lineBreaks(2)
            if mode == .markdown {
                let level = Int(String(tag.dropFirst())) ?? 1
                appendLiteral(String(repeating: "#", count: level) + " ", consumingPendingSpace: false)
            }
        case "p", "article", "section", "main", "header", "footer", "address":
            lineBreaks(2)
        case "div":
            lineBreaks(1)
        case "br":
            lineBreaks(1)
        case "hr":
            lineBreaks(2)
            appendLiteral(mode == .markdown ? "---" : "———", consumingPendingSpace: false)
            lineBreaks(2)
        case "ul", "ol":
            lineBreaks(1)
        case "li":
            lineBreaks(1)
            appendLiteral(listPrefix(for: element), consumingPendingSpace: false)
        case "blockquote":
            lineBreaks(1)
            appendLiteral(mode == .markdown ? "> " : "│ ", consumingPendingSpace: false)
        case "pre":
            lineBreaks(2)
            if mode == .markdown {
                appendLiteral("```\n", consumingPendingSpace: false)
            }
            preformattedDepth += 1
        case "strong", "b":
            if mode == .markdown { appendOpeningMarkup("**") }
        case "em", "i":
            if mode == .markdown { appendOpeningMarkup("*") }
        case "code":
            if mode == .markdown && preformattedDepth == 0 { appendOpeningMarkup("`") }
        case "a":
            guard mode == .markdown,
                  let destination = MailHTMLReader.safeLinkDestination(try element.attr("href")) else { return }
            appendOpeningMarkup("[")
            links[ObjectIdentifier(element)] = (output.utf8.count, destination)
        case "img":
            let alt = try element.attr("alt").trimmingCharacters(in: .whitespacesAndNewlines)
            if !alt.isEmpty {
                appendOpeningMarkup(mode == .markdown ? "[Image: " : "Image: ")
                appendText(alt, preformatted: false)
                appendLiteral(mode == .markdown ? "]" : "", consumingPendingSpace: false)
            }
        case "tr":
            lineBreaks(1)
        case "td", "th":
            if hasContentOnCurrentLine() {
                appendLiteral("  ·  ", consumingPendingSpace: true)
            }
        default:
            break
        }
    }

    func tail(_ node: Node, _ depth: Int) throws {
        guard let element = node as? Element else { return }
        let tag = element.tagNameNormal()
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6", "p", "article", "section", "main", "header", "footer", "address":
            lineBreaks(2)
        case "div", "li", "blockquote", "tr":
            lineBreaks(1)
        case "pre":
            preformattedDepth = max(0, preformattedDepth - 1)
            if mode == .markdown {
                lineBreaks(1)
                appendLiteral("```", consumingPendingSpace: false)
            }
            lineBreaks(2)
        case "strong", "b":
            if mode == .markdown { appendLiteral("**", consumingPendingSpace: false) }
        case "em", "i":
            if mode == .markdown { appendLiteral("*", consumingPendingSpace: false) }
        case "code":
            if mode == .markdown && preformattedDepth == 0 {
                appendLiteral("`", consumingPendingSpace: false)
            }
        case "a":
            guard mode == .markdown,
                  let link = links.removeValue(forKey: ObjectIdentifier(element)) else { return }
            if output.utf8.count == link.start {
                appendText(linkLabel(for: link.destination), preformatted: false)
            }
            appendLiteral("](<\(link.destination)>)", consumingPendingSpace: false)
        default:
            break
        }
    }

    private func appendText(_ rawText: String, preformatted: Bool) {
        guard !rawText.isEmpty else { return }
        if preformatted {
            appendLiteral(
                rawText.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n"),
                consumingPendingSpace: true
            )
            return
        }

        let cleaned = rawText.replacingOccurrences(of: "\u{00a0}", with: " ")
        let words = cleaned.split(whereSeparator: \Character.isWhitespace)
        guard !words.isEmpty else {
            pendingSpace = pendingSpace || cleaned.contains(where: \Character.isWhitespace)
            return
        }

        let hasLeadingSpace = cleaned.first?.isWhitespace == true
        if (pendingSpace || hasLeadingSpace), shouldInsertSpace() {
            appendLiteral(" ", consumingPendingSpace: false)
        }
        let text = words.joined(separator: " ")
        appendLiteral(
            mode == .markdown ? MailHTMLReader.escapedMarkdownText(text) : text,
            consumingPendingSpace: false
        )
        pendingSpace = cleaned.last?.isWhitespace == true
    }

    private func appendOpeningMarkup(_ text: String) {
        appendLiteral(text, consumingPendingSpace: true)
    }

    private func appendLiteral(_ text: String, consumingPendingSpace: Bool) {
        guard !text.isEmpty, output.utf8.count < MailHTMLReader.maximumOutputBytes else { return }
        if consumingPendingSpace, pendingSpace, shouldInsertSpace() {
            output.append(" ")
        }
        if consumingPendingSpace { pendingSpace = false }
        let remaining = MailHTMLReader.maximumOutputBytes - output.utf8.count
        output.append(String(decoding: text.utf8.prefix(remaining), as: UTF8.self))
    }

    private func lineBreaks(_ requested: Int) {
        pendingSpace = false
        while output.last == " " || output.last == "\t" { output.removeLast() }
        let existing = output.reversed().prefix(while: { $0 == "\n" }).count
        if existing < requested {
            appendLiteral(String(repeating: "\n", count: requested - existing), consumingPendingSpace: false)
        }
    }

    private func shouldInsertSpace() -> Bool {
        guard let last = output.last, !last.isWhitespace else { return false }
        return !["[", "(", "{", "/", "\n"].contains(last)
    }

    private func hasContentOnCurrentLine() -> Bool {
        guard let lastNewline = output.lastIndex(of: "\n") else { return !output.isEmpty }
        return output[output.index(after: lastNewline)...].contains { !$0.isWhitespace }
    }

    private func listPrefix(for element: Element) -> String {
        guard let parent = element.parent(), parent.tagNameNormal() == "ol" else { return "• " }
        let ordinal = parent.children().enumerated().first { $0.element === element }?.offset ?? 0
        return "\(ordinal + 1). "
    }

    private func linkLabel(for destination: String) -> String {
        guard let components = URLComponents(string: destination) else { return destination }
        return components.host ?? components.path
    }

    private func boundedResult(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count >= MailHTMLReader.maximumOutputBytes else { return trimmed }
        return trimmed + "\n\nMessage text was truncated for safe display."
    }
}
