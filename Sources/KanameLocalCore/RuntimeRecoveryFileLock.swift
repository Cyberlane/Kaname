import Foundation
import Darwin

public enum KanameRuntimeRecoveryFileLockError: Error {
    case unavailable
}

public final class KanameRuntimeRecoveryFileLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        _ = Darwin.close(descriptor)
    }
    public static func acquireShared(applicationSupportRoot: URL) throws -> KanameRuntimeRecoveryFileLock {
        try acquire(applicationSupportRoot: applicationSupportRoot, type: Int16(F_RDLCK), command: F_SETLK)
    }

    public static func acquireExclusiveNonblocking(applicationSupportRoot: URL) throws -> KanameRuntimeRecoveryFileLock {
        try acquire(applicationSupportRoot: applicationSupportRoot, type: Int16(F_WRLCK), command: F_SETLK)
    }

    private static func acquire(
        applicationSupportRoot: URL,
        type: Int16,
        command: Int32
    ) throws -> KanameRuntimeRecoveryFileLock {
        let runtime = applicationSupportRoot.appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let values = try runtime.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              chmod(runtime.path, 0o700) == 0 else {
            throw KanameRuntimeRecoveryFileLockError.unavailable
        }
        let url = runtime.appendingPathComponent("recovery-runtime.lock")
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw KanameRuntimeRecoveryFileLockError.unavailable }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1,
              Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            _ = Darwin.close(descriptor)
            throw KanameRuntimeRecoveryFileLockError.unavailable
        }
        var lock = flock()
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, command, &lock) == 0 else {
            _ = Darwin.close(descriptor)
            throw KanameRuntimeRecoveryFileLockError.unavailable
        }
        return KanameRuntimeRecoveryFileLock(descriptor: descriptor)
    }
}
