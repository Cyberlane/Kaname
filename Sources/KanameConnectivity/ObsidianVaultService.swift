import CryptoKit
import Foundation

public struct ObsidianDocumentSnapshot: Equatable, Sendable {
    public let path: String
    public let content: String
    public let digest: String
    public let wikilinks: [String]
    public let backlinks: [String]
    public let properties: [String: String]
    public let attachments: [String]
    public let wasTruncated: Bool
}

public struct ObsidianSearchResult: Equatable, Identifiable, Sendable {
    public let id: String
    public let path: String
    public let context: String
}

public struct ObsidianNoteDiff: Equatable, Sendable {
    public let targetPath: String
    public let baseDigest: String
    public let proposedDigest: String
    public let summary: String
    public let unifiedDiff: String
}

public struct ObsidianNoteMutationGrant: Equatable, Sendable {
    public let approvalID: String
    public let targetPath: String
    public let baseDigest: String

    public init(approvalID: String, targetPath: String, baseDigest: String) {
        self.approvalID = approvalID
        self.targetPath = targetPath
        self.baseDigest = baseDigest
    }
}

public enum ObsidianVaultError: Error, Equatable, LocalizedError, Sendable {
    case invalidScope
    case outsideScope
    case documentTooLarge
    case approvalMismatch
    case conflict(currentDigest: String)
    case commandFailed(String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidScope: "Choose a vault-relative Markdown path without traversal components."
        case .outsideScope: "This note is outside the explicitly selected vault scope."
        case .documentTooLarge: "The note exceeds Kaname's one-megabyte native editing limit."
        case .approvalMismatch: "The approval does not match this exact note and base revision."
        case let .conflict(digest): "The note changed since the proposal was created (current revision \(digest.prefix(12)))."
        case let .commandFailed(detail): detail
        case .malformedResponse: "Obsidian returned a response Kaname could not safely reconcile."
        }
    }
}

public actor ObsidianVaultService {
    private static let maximumDocumentBytes = 1_048_576
    private let readableScopes: [String]
    private let writableScopes: [String]
    private let timeout: Duration
    private let executable: String

    public init(
        readableScopes: [String],
        writableScopes: [String],
        timeout: Duration = .seconds(10),
        executable: String = "obsidian"
    ) throws {
        self.readableScopes = try readableScopes.map(Self.validatedScope)
        self.writableScopes = try writableScopes.map(Self.validatedScope)
        self.timeout = timeout
        self.executable = executable
    }

    public func inspect(path: String) async throws -> ObsidianDocumentSnapshot {
        let target = try authorize(path: path, against: readableScopes)
        async let contentText = command(["read", "path=\(target)"])
        async let backlinkText = command(["backlinks", "path=\(target)", "format=json"])
        async let propertyText = command(["properties", "path=\(target)", "format=json"])
        let (contentOutput, backlinkOutput, propertyOutput) = try await (contentText, backlinkText, propertyText)
        guard contentOutput.utf8.count <= Self.maximumDocumentBytes else { throw ObsidianVaultError.documentTooLarge }
        return ObsidianDocumentSnapshot(
            path: target,
            content: contentOutput,
            digest: Self.digest(contentOutput),
            wikilinks: Self.wikilinks(in: contentOutput),
            backlinks: Self.paths(fromJSON: backlinkOutput),
            properties: Self.properties(fromJSON: propertyOutput),
            attachments: Self.attachments(in: contentOutput),
            wasTruncated: false
        )
    }

    public func search(query: String, scope: String, limit: Int = 50) async throws -> [ObsidianSearchResult] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty, cleanQuery.utf8.count <= 512 else { return [] }
        let folder = try authorize(path: scope, against: readableScopes)
        let output = try await command([
            "search:context", "query=\(cleanQuery)", "path=\(folder)", "limit=\(min(max(limit, 1), 100))", "format=json",
        ])
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            throw ObsidianVaultError.malformedResponse
        }
        return Self.searchResults(from: value)
    }

    public func proposedDiff(path: String, baseContent: String, proposedContent: String) throws -> ObsidianNoteDiff {
        let target = try authorize(path: path, against: writableScopes)
        guard baseContent.utf8.count <= Self.maximumDocumentBytes,
              proposedContent.utf8.count <= Self.maximumDocumentBytes else {
            throw ObsidianVaultError.documentTooLarge
        }
        let oldLines = baseContent.components(separatedBy: .newlines)
        let newLines = proposedContent.components(separatedBy: .newlines)
        let commonPrefix = zip(oldLines, newLines).prefix { $0 == $1 }.count
        let oldRemainder = oldLines.dropFirst(commonPrefix)
        let newRemainder = newLines.dropFirst(commonPrefix)
        let commonSuffix = zip(oldRemainder.reversed(), newRemainder.reversed()).prefix { $0 == $1 }.count
        let removed = oldRemainder.dropLast(commonSuffix)
        let added = newRemainder.dropLast(commonSuffix)
        let contextBefore = oldLines.prefix(commonPrefix).suffix(3).map { " \($0)" }
        let contextAfter = oldLines.suffix(commonSuffix).prefix(3).map { " \($0)" }
        let diffLines = ["--- \(target)", "+++ \(target)"]
            + contextBefore
            + removed.prefix(500).map { "-\($0)" }
            + added.prefix(500).map { "+\($0)" }
            + contextAfter
        return ObsidianNoteDiff(
            targetPath: target,
            baseDigest: Self.digest(baseContent),
            proposedDigest: Self.digest(proposedContent),
            summary: "\(removed.count) removed · \(added.count) added line\(added.count == 1 ? "" : "s")",
            unifiedDiff: diffLines.joined(separator: "\n")
        )
    }

    public func write(path: String, content: String, grant: ObsidianNoteMutationGrant) async throws -> ObsidianDocumentSnapshot {
        let target = try authorize(path: path, against: writableScopes)
        guard grant.targetPath == target else { throw ObsidianVaultError.approvalMismatch }
        guard content.utf8.count <= Self.maximumDocumentBytes else { throw ObsidianVaultError.documentTooLarge }
        let current = try await inspectForWriteOrEmpty(path: target)
        guard grant.baseDigest == current.digest else { throw ObsidianVaultError.conflict(currentDigest: current.digest) }
        let pathLiteral = try Self.jsonLiteral(target)
        let contentLiteral = try Self.jsonLiteral(content)
        // Creates the note (and missing parent folders) when the approved base
        // revision is the empty document; otherwise replaces the existing note.
        let code = "(async()=>{const p=\(pathLiteral);let f=app.vault.getAbstractFileByPath(p);if(!f){const parts=p.split('/');parts.pop();let dir='';for(const part of parts){dir=dir?dir+'/'+part:part;if(!app.vault.getAbstractFileByPath(dir)){await app.vault.createFolder(dir)}}await app.vault.create(p,\(contentLiteral));return true}await app.vault.modify(f,\(contentLiteral));return true})()"
        _ = try await command(["eval", "code=\(code)"], maximumBytes: 32_768)
        let reconciled = try await inspectForWrite(path: target)
        guard reconciled.digest == Self.digest(content) else { throw ObsidianVaultError.malformedResponse }
        return reconciled
    }

    /// Snapshot of a note that does not exist yet: empty content, empty digest.
    public static func emptyDocument(path: String) -> ObsidianDocumentSnapshot {
        ObsidianDocumentSnapshot(
            path: path,
            content: "",
            digest: digest(""),
            wikilinks: [],
            backlinks: [],
            properties: [:],
            attachments: [],
            wasTruncated: false
        )
    }

    /// Like `inspect`, but a missing note yields the empty document so a
    /// caller can seed a draft that creates it.
    public func inspectOrEmpty(path: String) async throws -> ObsidianDocumentSnapshot {
        let target = try authorize(path: path, against: writableScopes)
        do {
            return try await inspect(path: target)
        } catch ObsidianVaultError.commandFailed {
            return Self.emptyDocument(path: target)
        }
    }

    private func inspectForWriteOrEmpty(path: String) async throws -> ObsidianDocumentSnapshot {
        do {
            return try await inspectForWrite(path: path)
        } catch ObsidianVaultError.commandFailed {
            return Self.emptyDocument(path: path)
        }
    }

    private func inspectForWrite(path: String) async throws -> ObsidianDocumentSnapshot {
        let output = try await command(["read", "path=\(path)"])
        guard output.utf8.count <= Self.maximumDocumentBytes else { throw ObsidianVaultError.documentTooLarge }
        return ObsidianDocumentSnapshot(
            path: path,
            content: output,
            digest: Self.digest(output),
            wikilinks: Self.wikilinks(in: output),
            backlinks: [],
            properties: [:],
            attachments: Self.attachments(in: output),
            wasTruncated: false
        )
    }

    private func authorize(path: String, against scopes: [String]) throws -> String {
        let target = try Self.validatedPath(path)
        guard scopes.contains(where: { scope in
            target == scope || target.hasPrefix(scope.hasSuffix("/") ? scope : scope + "/")
        }) else { throw ObsidianVaultError.outsideScope }
        return target
    }

    private func command(_ arguments: [String], maximumBytes: Int = 2_097_152) async throws -> String {
        do {
            return try await LocalProcess.captureSuccessfulText(
                executable: executable,
                arguments: arguments,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                timeout: timeout,
                environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals(),
                maximumOutputBytes: maximumBytes,
                preserveWhitespace: true
            ).trimmingCharacters(in: .newlines)
        } catch {
            throw ObsidianVaultError.commandFailed(error.localizedDescription)
        }
    }

    static func validatedPath(_ value: String) throws -> String {
        do {
            return try VaultRelativePathValidator.validate(value, maximumBytes: 2_048)
        } catch {
            throw ObsidianVaultError.invalidScope
        }
    }

    private static func validatedScope(_ value: String) throws -> String {
        var scope = try validatedPath(value)
        while scope.hasSuffix("/") { scope.removeLast() }
        return scope
    }

    private static func digest(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else { throw ObsidianVaultError.malformedResponse }
        return literal
    }

    private static func wikilinks(in content: String) -> [String] {
        matches(pattern: #"(?<!!)\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]"#, in: content)
    }

    private static func attachments(in content: String) -> [String] {
        let embeds = matches(pattern: #"!\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]"#, in: content)
        let markdown = matches(pattern: #"!\[[^\]]*\]\(([^)]+)\)"#, in: content)
        return Array(Set(embeds + markdown)).sorted()
    }

    private static func matches(pattern: String, in content: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(content.startIndex..., in: content)
        return Array(Set(expression.matches(in: content, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let valueRange = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
    }

    private static func paths(fromJSON text: String) -> [String] {
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return Array(Set(extractStrings(from: value, keys: ["path", "file"]))).sorted()
    }

    private static func properties(fromJSON text: String) -> [String: String] {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.reduce(into: [:]) { result, pair in
            if let text = pair.value as? String { result[pair.key] = text }
            else if JSONSerialization.isValidJSONObject(pair.value),
                    let data = try? JSONSerialization.data(withJSONObject: pair.value, options: [.sortedKeys]) {
                result[pair.key] = String(decoding: data, as: UTF8.self)
            } else { result[pair.key] = String(describing: pair.value) }
        }
    }

    private static func extractStrings(from value: Any, keys: Set<String>) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, child in
                let own: [String]
                if keys.contains(key), let text = child as? String {
                    own = [text]
                } else {
                    own = []
                }
                return own + extractStrings(from: child, keys: keys)
            }
        }
        if let array = value as? [Any] { return array.flatMap { extractStrings(from: $0, keys: keys) } }
        return value as? String != nil ? [] : []
    }

    private static func searchResults(from value: Any) -> [ObsidianSearchResult] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { item in
            if let path = item as? String { return ObsidianSearchResult(id: path, path: path, context: "") }
            guard let object = item as? [String: Any],
                  let path = (object["path"] ?? object["file"]) as? String else { return nil }
            let context: String
            if let supplied = object["context"] as? String {
                context = supplied
            } else if let matched = object["match"] as? String {
                context = matched
            } else {
                context = object["text"] as? String ?? ""
            }
            return ObsidianSearchResult(id: path, path: path, context: context)
        }
    }
}
