import Foundation

public struct DesktopProjectFolderEntry: Equatable, Identifiable, Sendable {
    public let name: String
    public let path: String
    public let isParent: Bool

    public var id: String { path }
}

public struct DesktopProjectFolderBrowserSnapshot: Equatable, Sendable {
    public let requestedPath: String
    public let displayPath: String
    public let directoryPath: String
    public let parentDirectoryPath: String?
    public let existingDirectoryPath: String?
    public let entries: [DesktopProjectFolderEntry]
}

public enum DesktopProjectFolderBrowserError: Error, Equatable, LocalizedError, Sendable {
    case invalidPath(String)
    case unreadableDirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(detail), let .unreadableDirectory(detail): detail
        }
    }
}

public actor DesktopProjectFolderBrowser {
    public init() {}

    public static func defaultPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projects = home.appending(path: "Projects", directoryHint: .isDirectory)
        let initial = Self.isDirectory(projects) ? projects : home
        return Self.displayPath(initial, trailingSlash: true)
    }

    public func browse(path: String) throws -> DesktopProjectFolderBrowserSnapshot {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = trimmed.isEmpty ? Self.defaultPath() : trimmed
        let expanded = (input as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw DesktopProjectFolderBrowserError.invalidPath(
                "Enter an absolute folder path, or a path beginning with ~."
            )
        }

        let requestedURL = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        let hadTrailingSlash = requestedURL.path != "/" && expanded.hasSuffix("/")
        let exactDirectory = Self.isDirectory(requestedURL)
        let directoryURL: URL
        let filter: String
        if exactDirectory {
            directoryURL = requestedURL
            filter = ""
        } else {
            directoryURL = requestedURL.deletingLastPathComponent().standardizedFileURL
            filter = requestedURL.lastPathComponent
            guard Self.isDirectory(directoryURL) else {
                throw DesktopProjectFolderBrowserError.invalidPath(
                    "Enter an existing folder path to browse its directories."
                )
            }
        }

        let entries = try Self.directoryEntries(at: directoryURL, matching: filter)
        let displayPath = Self.displayPath(
            exactDirectory ? directoryURL : requestedURL,
            trailingSlash: exactDirectory || hadTrailingSlash
        )
        let parentPath = directoryURL.path == "/"
            ? nil
            : directoryURL.deletingLastPathComponent().standardizedFileURL.path

        return DesktopProjectFolderBrowserSnapshot(
            requestedPath: input,
            displayPath: displayPath,
            directoryPath: directoryURL.path,
            parentDirectoryPath: parentPath,
            existingDirectoryPath: exactDirectory ? requestedURL.path : nil,
            entries: entries
        )
    }

    private static func directoryEntries(
        at directory: URL,
        matching filter: String
    ) throws -> [DesktopProjectFolderEntry] {
        let fileManager = FileManager.default
        let showHidden = filter.hasPrefix(".")
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            throw DesktopProjectFolderBrowserError.unreadableDirectory(
                "Kaname could not read \(Self.displayPath(directory, trailingSlash: true))."
            )
        }

        var entries: [DesktopProjectFolderEntry] = []
        if directory.path != "/" {
            entries.append(
                DesktopProjectFolderEntry(
                    name: "..",
                    path: directory.deletingLastPathComponent().standardizedFileURL.path,
                    isParent: true
                )
            )
        }

        var matchingEntries: [DesktopProjectFolderEntry] = []
        for url in urls {
            let name = url.lastPathComponent
            guard !name.isEmpty,
                  Self.isDirectory(url),
                  (showHidden || !name.hasPrefix(".")),
                  filter.isEmpty || name.localizedCaseInsensitiveContains(filter) else {
                continue
            }
            matchingEntries.append(
                DesktopProjectFolderEntry(name: name, path: url.standardizedFileURL.path, isParent: false)
            )
        }
        matchingEntries.sort(by: Self.areEntriesOrdered)
        entries.append(contentsOf: matchingEntries)
        return entries
    }

    private static func areEntriesOrdered(
        _ left: DesktopProjectFolderEntry,
        _ right: DesktopProjectFolderEntry
    ) -> Bool {
        switch left.name.localizedCaseInsensitiveCompare(right.name) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return left.path < right.path
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func displayPath(_ url: URL, trailingSlash: Bool) -> String {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let abbreviated: String
        if path == home {
            abbreviated = "~"
        } else if path.hasPrefix(home + "/") {
            abbreviated = "~" + String(path.dropFirst(home.count))
        } else {
            abbreviated = path
        }
        if trailingSlash, abbreviated != "/" { return abbreviated + "/" }
        return abbreviated
    }
}
