#if os(macOS)
import Darwin
import Foundation

public enum KanameLinkTunnelEnrollmentError: Error, Equatable, LocalizedError, Sendable {
    case inputIsNotAnonymousPipe
    case inputReadFailed
    case inputTooLarge(limit: Int)
    case emptyInput

    public var errorDescription: String? {
        switch self {
        case .inputIsNotAnonymousPipe:
            "Tunnel credential enrollment requires an anonymous standard-input pipe."
        case .inputReadFailed:
            "The tunnel credential could not be read from its anonymous pipe."
        case let .inputTooLarge(limit):
            "The tunnel credential exceeded the \(limit)-byte enrollment limit."
        case .emptyInput:
            "The anonymous enrollment pipe contained no tunnel credential."
        }
    }
}

protocol KanameLinkTunnelTokenInputReading: Sendable {
    func readBounded(maximumBytes: Int) throws -> Data
}

/// A read channel accepted only when its descriptor is an unlinked POSIX pipe,
/// never a terminal, regular file, socket, or named FIFO.
struct KanameLinkTunnelAnonymousStandardInput: KanameLinkTunnelTokenInputReading,
    @unchecked Sendable
{
    private let handle: FileHandle

    init(handle: FileHandle = .standardInput) throws {
        let descriptor = handle.fileDescriptor
        var metadata = stat()
        guard descriptor >= 0,
              isatty(descriptor) == 0,
              fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO),
              metadata.st_nlink == 0 else {
            throw KanameLinkTunnelEnrollmentError.inputIsNotAnonymousPipe
        }
        self.handle = handle
    }

    func readBounded(maximumBytes: Int) throws -> Data {
        var result = Data()
        var shouldScrubResult = true
        defer {
            if shouldScrubResult {
                result.resetBytes(in: result.startIndex ..< result.endIndex)
            }
        }
        do {
            while true {
                let remaining = maximumBytes - result.count
                let requestCount = max(1, min(1_024, remaining + 1))
                guard var chunk = try handle.read(upToCount: requestCount), !chunk.isEmpty else {
                    shouldScrubResult = false
                    return result
                }
                result.append(chunk)
                chunk.resetBytes(in: chunk.startIndex ..< chunk.endIndex)
                if result.count > maximumBytes {
                    throw KanameLinkTunnelEnrollmentError.inputTooLarge(limit: maximumBytes)
                }
            }
        } catch let failure as KanameLinkTunnelEnrollmentError {
            throw failure
        } catch {
            throw KanameLinkTunnelEnrollmentError.inputReadFailed
        }
    }
}

public struct KanameLinkTunnelTokenEnrollment: Sendable {
    private let credentialStore: any KanameLinkTunnelCredentialStoring

    public init(credentialStore: any KanameLinkTunnelCredentialStoring) {
        self.credentialStore = credentialStore
    }

    /// Reads one bounded token from this process's anonymous stdin and replaces
    /// the fixed Keychain item. No token is accepted in arguments or files.
    public func enrollFromAnonymousStandardInput() throws {
        try enroll(from: KanameLinkTunnelAnonymousStandardInput())
    }

    /// Same boundary for an anonymous pipe created inside the primary host.
    public func enrollFromAnonymousPipe(readingHandle: FileHandle) throws {
        try enroll(from: KanameLinkTunnelAnonymousStandardInput(handle: readingHandle))
    }

    /// Explicitly deletes the local credential only. It is never called by
    /// launch, stop, failed enrollment, or rollback paths.
    public func deleteLocalCredential() throws {
        try credentialStore.deleteToken()
    }

    func enroll(from input: any KanameLinkTunnelTokenInputReading) throws {
        let maximumInputBytes = KanameLinkTunnelToken.maximumByteCount + 2
        var raw = try input.readBounded(maximumBytes: maximumInputBytes)
        defer {
            raw.resetBytes(in: raw.startIndex ..< raw.endIndex)
        }
        guard !raw.isEmpty else {
            throw KanameLinkTunnelEnrollmentError.emptyInput
        }

        var normalized = raw
        defer {
            normalized.resetBytes(in: normalized.startIndex ..< normalized.endIndex)
        }
        if normalized.suffix(2).elementsEqual([0x0D, 0x0A]) {
            normalized.removeLast(2)
        } else if normalized.last == 0x0A {
            normalized.removeLast()
        }
        let token = try KanameLinkTunnelToken(data: normalized)
        try credentialStore.replaceToken(token)
    }
}
#endif
