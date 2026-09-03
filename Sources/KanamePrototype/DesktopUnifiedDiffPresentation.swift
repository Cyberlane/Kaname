import Foundation

/// Parses a unified diff for one file into rows the Changes tab can render with
/// an old/new line-number gutter. Pure and allocation-light; the raw patch stays
/// the source of truth for copy and selection.
enum DesktopUnifiedDiffPresentation {
    struct Row: Identifiable {
        enum Kind { case header, hunk, context, added, removed, meta }
        let id: Int
        let kind: Kind
        let oldLine: Int?
        let newLine: Int?
        let text: String
    }

    struct Summary {
        let rows: [Row]
        let added: Int
        let removed: Int
        let hunks: Int
        let isBinary: Bool
    }

    static func parse(_ patch: String) -> Summary {
        var rows: [Row] = []
        var added = 0, removed = 0, hunks = 0
        var oldLine = 0, newLine = 0
        var isBinary = false
        var id = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            defer { id += 1 }
            if line.hasPrefix("@@") {
                hunks += 1
                let numbers = hunkNumbers(line)
                oldLine = numbers.old
                newLine = numbers.new
                rows.append(Row(id: id, kind: .hunk, oldLine: nil, newLine: nil, text: hunkContext(line)))
            } else if line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                        || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") || line.hasPrefix("old mode") || line.hasPrefix("new mode")
                        || line.hasPrefix("similarity index") || line.hasPrefix("rename from") || line.hasPrefix("rename to") {
                rows.append(Row(id: id, kind: .header, oldLine: nil, newLine: nil, text: line))
            } else if line.hasPrefix("Binary files") {
                isBinary = true
                rows.append(Row(id: id, kind: .meta, oldLine: nil, newLine: nil, text: line))
            } else if line.hasPrefix("\\ No newline") {
                rows.append(Row(id: id, kind: .meta, oldLine: nil, newLine: nil, text: line))
            } else if line.hasPrefix("+") {
                added += 1
                rows.append(Row(id: id, kind: .added, oldLine: nil, newLine: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-") {
                removed += 1
                rows.append(Row(id: id, kind: .removed, oldLine: oldLine, newLine: nil, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix(" ") || (line.isEmpty && hunks > 0) {
                rows.append(Row(id: id, kind: .context, oldLine: oldLine, newLine: newLine, text: line.isEmpty ? "" : String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            } else if !line.isEmpty {
                rows.append(Row(id: id, kind: .meta, oldLine: nil, newLine: nil, text: line))
            }
        }
        // Trailing empty row from the final newline carries no content.
        if let last = rows.last, last.kind == .context, last.text.isEmpty, patch.hasSuffix("\n") {
            rows.removeLast()
        }
        return Summary(rows: rows, added: added, removed: removed, hunks: hunks, isBinary: isBinary)
    }

    /// `@@ -a,b +c,d @@ ctx` → (a, c)
    private static func hunkNumbers(_ line: String) -> (old: Int, new: Int) {
        let parts = line.split(separator: " ")
        func start(_ token: Substring) -> Int {
            let body = token.dropFirst() // drop - or +
            let first = body.split(separator: ",").first ?? body
            return Int(first) ?? 0
        }
        let old = parts.indices.contains(1) ? start(parts[1]) : 0
        let new = parts.indices.contains(2) ? start(parts[2]) : 0
        return (old, new)
    }

    /// Text after the second `@@`, if any, otherwise the raw header.
    private static func hunkContext(_ line: String) -> String {
        guard let range = line.range(of: "@@", options: .backwards), range.upperBound < line.endIndex else { return line }
        let context = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let header = line[..<range.upperBound]
        return context.isEmpty ? String(header) : "\(header)  \(context)"
    }
}
