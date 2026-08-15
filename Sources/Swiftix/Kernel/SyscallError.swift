/// A typed, POSIX-errno-style error surfaced by the throwing syscall frontend.
///
/// Throwing syscalls express failure through this error so callers can switch on
/// the failure cause. Each case exposes an errno-style numeric `code` matching the
/// Linux errno value it models.
///
/// End-of-stream (EOF) is deliberately *not* a case here: a healthy stream at end
/// of stream returns an empty byte sequence as a successful read, keeping EOF
/// distinct from `.wouldBlock` and from any hard error.
public enum SyscallError: Error, Equatable, Sendable {
    /// A path did not resolve to an existing node and creation was not requested (ENOENT).
    case noSuchFileOrDirectory
    /// A descriptor is not allocated in the calling process, or is the wrong object type (EBADF).
    case badFileDescriptor
    /// A blocking operation was interrupted by process termination or a signal (EINTR).
    case interrupted
    /// A non-blocking operation has nothing ready right now (EAGAIN).
    case wouldBlock
    /// A wait was requested but the process has no living or un-waited children (ECHILD).
    case noChildProcess
    /// A directory was opened as if it were a regular file (EISDIR).
    case isADirectory
    /// A path expected to name a directory names another file type (ENOTDIR).
    case notADirectory
    /// A directory removal was requested for a non-empty directory (ENOTEMPTY).
    case directoryNotEmpty
    /// Exclusive create was requested but the file already exists (EEXIST).
    case fileExists
    /// The connection was aborted by an inbound RST (ECONNRESET).
    case connectionReset
    /// The socket is not connected (ENOTCONN).
    case notConnected
    /// An argument was invalid, e.g. a buffered datagram whose fields cannot be extracted (EINVAL).
    case invalidArgument
    /// The caller's credentials do not permit the requested access to the file (EACCES).
    case permissionDenied
    /// A capability-scoped path attempted to escape its preopened root.
    case capabilityViolation

    /// The errno-style numeric code for this failure (Linux values).
    public var code: Int32 {
        switch self {
        case .noSuchFileOrDirectory: return 2   // ENOENT
        case .interrupted:           return 4   // EINTR
        case .badFileDescriptor:     return 9   // EBADF
        case .noChildProcess:        return 10  // ECHILD
        case .permissionDenied, .capabilityViolation: return 13  // EACCES / ENOTCAPABLE analogue
        case .wouldBlock:            return 11  // EAGAIN
        case .fileExists:            return 17  // EEXIST
        case .notADirectory:          return 20  // ENOTDIR
        case .isADirectory:          return 21  // EISDIR
        case .invalidArgument:       return 22  // EINVAL
        case .connectionReset:       return 104 // ECONNRESET
        case .notConnected:          return 107 // ENOTCONN
        case .directoryNotEmpty:     return 39  // ENOTEMPTY
        }
    }
}
