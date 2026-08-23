#if os(macOS)
import Darwin
import Foundation

public enum KanameDesktopInstanceLockError: Error, Equatable, Sendable {
    case alreadyRunning
    case directoryUnavailable
    case lockFileUnavailable(Int32)
    case lockUnavailable(Int32)
}

/// An advisory process lock whose sharing boundary is defined by its URL.
///
/// The close-on-exec flag is essential because Kaname launches provider child
/// processes; those children must never keep the desktop-app lock alive.
public final class KanameDesktopInstanceLock: @unchecked Sendable {
    public static var defaultLockFileURL: URL {
        KanameDesktopEnvironment.current.instanceLockURL
    }

    private let descriptor: Int32

    public init(lockFileURL: URL = defaultLockFileURL) throws {
        let directory = lockFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw KanameDesktopInstanceLockError.directoryUnavailable
        }

        let opened = Darwin.open(
            lockFileURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard opened >= 0 else {
            throw KanameDesktopInstanceLockError.lockFileUnavailable(errno)
        }
        guard Darwin.fchmod(opened, S_IRUSR | S_IWUSR) == 0 else {
            let failure = errno
            Darwin.close(opened)
            throw KanameDesktopInstanceLockError.lockFileUnavailable(failure)
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            Darwin.close(opened)
            if failure == EWOULDBLOCK {
                throw KanameDesktopInstanceLockError.alreadyRunning
            }
            throw KanameDesktopInstanceLockError.lockUnavailable(failure)
        }
        descriptor = opened
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
#endif
