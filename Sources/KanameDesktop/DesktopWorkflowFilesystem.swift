import Foundation
#if os(macOS)
import Darwin
#endif

public enum DesktopWorkflowFilesystem {
    public static func preparePrivateDirectory(_ url: URL, failure: @autoclosure () -> any Error) throws {
        try createPrivateItem(at: url, isDirectory: true, mode: 0o700, failure: failure()) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    public static func writePrivate(_ data: Data, to url: URL, failure: @autoclosure () -> any Error) throws {
        try createPrivateItem(at: url, isDirectory: false, mode: 0o600, failure: failure()) {
            try data.write(to: url, options: [.atomic])
        }
    }

    static func requiredBoundedRegularData(
        at url: URL,
        maximumBytes: Int,
        requiresNonEmpty: Bool = false,
        mapped: Bool = false,
        failure: @autoclosure () -> any Error
    ) throws -> Data {
        guard let data = try boundedRegularData(
            at: url,
            maximumBytes: maximumBytes,
            requiresNonEmpty: requiresNonEmpty,
            mapped: mapped
        ) else { throw failure() }
        return data
    }

    private static func requirePrivateMode(
        _ url: URL,
        isDirectory: Bool,
        mode: mode_t,
        failure: @autoclosure () -> any Error
    ) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
              isDirectory ? values.isDirectory == true : values.isRegularFile == true else { throw failure() }
#if os(macOS)
        guard chmod(url.path, mode) == 0 else { throw failure() }
#endif
    }

    private static func createPrivateItem(
        at url: URL,
        isDirectory: Bool,
        mode: mode_t,
        failure: @autoclosure () -> any Error,
        create: () throws -> Void
    ) throws {
        try create()
        try requirePrivateMode(url, isDirectory: isDirectory, mode: mode, failure: failure())
    }

    static func boundedRegularData(
        at url: URL,
        maximumBytes: Int,
        requiresNonEmpty: Bool = false,
        mapped: Bool = false
    ) throws -> Data? {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= (requiresNonEmpty ? 1 : 0), size <= maximumBytes else {
            return nil
        }
        return try Data(contentsOf: url, options: mapped ? [.mappedIfSafe] : [])
    }
}
