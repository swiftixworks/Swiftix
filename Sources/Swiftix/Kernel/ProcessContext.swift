/// The syscall surface handed to a running process. This is the boundary between
/// user programs and the kernel. It deliberately mirrors POSIX *semantics*
/// through a Swift-native API rather than a binary syscall-number ABI; Swiftix
/// does not run unmodified Linux ELF binaries.
public final class ProcessContext {
    /// `unowned`: a context is a transient executable handle. The kernel keeps
    /// the identity alive while user code runs and never schedules it after
    /// logical exit (see `Kernel.runStep`), so this is always valid in use — and
    /// being unowned avoids a process <-> context retain cycle when a blocking
    /// continuation captures the context.
    unowned let process: Process
    unowned let kernel: Kernel

    init(process: Process, kernel: Kernel) {
        self.process = process
        self.kernel = kernel
    }

    /// The node's single logical clock and serial event driver. User-language
    /// runtimes use this same loop for timers and park/wake integration instead
    /// of creating a second clock that could diverge from kernel time.
    public var eventLoop: EventLoop { kernel.loop }

    /// Schedule runtime work in this process's Kernel lifecycle scope. Embedded
    /// runtimes should prefer this over scheduling directly on `eventLoop`, so a
    /// VM suspend freezes their timers and process exit physically cancels them.
    public func schedule(after delay: Double, _ work: @escaping () -> Void) {
        kernel.schedule(for: process, after: delay, work)
    }

    /// This process's mount-namespace view, passed to every VFS path operation so
    /// lookups and creations are redirected into whatever is mounted for *this*
    /// namespace (see `MountNamespace`).
    var mountNS: MountNamespace { process.mountNamespace }

    // MARK: - Helpers

    /// Resolve `path` to a normalized absolute path: prepend the cwd when
    /// relative, then collapse `.` and `..` components. Normalizing here means
    /// every syscall that takes a path (`open`, `listDirectory`, `chdir`, …)
    /// accepts relative paths and `..` uniformly.
    func absolute(_ path: String) -> String {
        let joined = path.hasPrefix("/")
            ? path
            : (process.cwd == "/" ? "/" + path : process.cwd + "/" + path)
        var stack: [Substring] = []
        for part in joined.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(part)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    /// Record one completed Swiftix syscall using a whitespace-free detail token
    /// so `/proc/<pid>/syscalls` remains line-oriented and mechanically parsable.
    func recordSyscall(_ name: String, result: String, detail: String = "-") {
        process.recordSyscall(
            name: name,
            result: result,
            detail: Self.syscallTraceToken(detail))
    }

    func recordSyscall(_ name: String, error: SyscallError, detail: String = "-") {
        recordSyscall(name, result: "-\(error.code)", detail: detail)
    }

    private static func syscallTraceToken(_ value: String) -> String {
        guard !value.isEmpty else { return "-" }
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)
        let digits = Array("0123456789ABCDEF".utf8)
        for byte in value.utf8 {
            if byte > 0x20, byte < 0x7f, byte != 0x25 {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded.append("%")
                encoded.append(Character(UnicodeScalar(digits[Int(byte >> 4)])))
                encoded.append(Character(UnicodeScalar(digits[Int(byte & 0x0f)])))
            }
        }
        return encoded
    }
}

/// The size of a terminal window in character cells — the moral equivalent of
/// `struct winsize`. A `Sendable` value type, like the other public value types,
/// so it crosses isolation boundaries freely.
public struct WindowSize: Sendable, Equatable {
    /// Height in rows (lines).
    public let rows: Int
    /// Width in columns (characters).
    public let columns: Int

    /// Creates a window size, clamping negatives to zero.
    public init(rows: Int, columns: Int) {
        self.rows = max(0, rows)
        self.columns = max(0, columns)
    }
}

public enum FileType: Sendable, Equatable {
    case regular
    case directory
    case symlink
    case fifo
}

/// One directory entry returned by capability-scoped enumeration. Keeping the
/// type and name together lets user runtimes consume directory metadata without
/// reaching through `ProcessContext` into VFS nodes.
public struct FileSystemDirectoryEntry: Sendable, Equatable {
    public let name: String
    public let type: FileType

    public init(name: String, type: FileType) {
        self.name = name
        self.type = type
    }
}

public struct FileMode: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let ownerRead = FileMode(rawValue: 0o400)
    public static let ownerWrite = FileMode(rawValue: 0o200)
    public static let ownerExecute = FileMode(rawValue: 0o100)
    public static let groupRead = FileMode(rawValue: 0o040)
    public static let groupWrite = FileMode(rawValue: 0o020)
    public static let groupExecute = FileMode(rawValue: 0o010)
    public static let otherRead = FileMode(rawValue: 0o004)
    public static let otherWrite = FileMode(rawValue: 0o002)
    public static let otherExecute = FileMode(rawValue: 0o001)

    public static let regularDefault: FileMode = [.ownerRead, .ownerWrite, .groupRead, .otherRead]
    public static let directoryDefault: FileMode = [
        .ownerRead, .ownerWrite, .ownerExecute,
        .groupRead, .groupExecute,
        .otherRead, .otherExecute,
    ]
    public static let symlinkDefault: FileMode = [
        .ownerRead, .ownerWrite, .ownerExecute,
        .groupRead, .groupWrite, .groupExecute,
        .otherRead, .otherWrite, .otherExecute,
    ]
    /// Named pipe default: rw-rw-rw- (0666), matching `mkfifo` without umask.
    public static let fifoDefault: FileMode = [
        .ownerRead, .ownerWrite,
        .groupRead, .groupWrite,
        .otherRead, .otherWrite,
    ]
}

public struct OpenFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let create = OpenFlags(rawValue: 1 << 0)
    public static let exclusive = OpenFlags(rawValue: 1 << 1)
    public static let truncate = OpenFlags(rawValue: 1 << 2)
    public static let append = OpenFlags(rawValue: 1 << 3)
    public static let nonBlocking = OpenFlags(rawValue: 1 << 4)
}

/// Access granted to an open descriptor. Keeping access mode separate from
/// `OpenFlags` mirrors POSIX's mutually-exclusive O_RDONLY/O_WRONLY/O_RDWR field
/// and lets the descriptor table reject reads/writes that were never authorized.
public enum FileAccessMode: Sendable, Equatable {
    case none
    case readOnly
    case writeOnly
    case readWrite

    public var canRead: Bool { self == .readOnly || self == .readWrite }
    public var canWrite: Bool { self == .writeOnly || self == .readWrite }
}

/// A filesystem capability rooted at one directory. Operations using this scope
/// accept only relative paths and cannot escape through `..` or absolute symlinks.
/// Package installation and user runtimes use it as a confined VFS boundary.
public struct FileSystemScope: Sendable, Equatable {
    public let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
    }
}

/// Metadata about a filesystem node (a small POSIX `stat` subset). A `Sendable`
/// value type, so it crosses isolation boundaries freely like the other public
/// value types.
public struct FileStat: Sendable, Equatable {
    public let type: FileType
    public let size: Int
    public let mode: FileMode
    /// Owner user ID.
    public let uid: UInt32
    /// Owner group ID.
    public let gid: UInt32
    /// Number of hard links (directory entries) pointing to this inode.
    public let nlink: Int
    /// Last access time (logical clock ticks).
    public let atime: Double
    /// Last modification time (logical clock ticks).
    public let mtime: Double
    /// Last status-change time (logical clock ticks).
    public let ctime: Double

    public var isDirectory: Bool { type == .directory }

    public init(type: FileType, size: Int, mode: FileMode, uid: UInt32 = 0, gid: UInt32 = 0,
                nlink: Int = 1, atime: Double = 0, mtime: Double = 0, ctime: Double = 0) {
        self.type = type
        self.size = size
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.nlink = nlink
        self.atime = atime
        self.mtime = mtime
        self.ctime = ctime
    }

    public init(isDirectory: Bool, size: Int) {
        self.type = isDirectory ? .directory : .regular
        self.size = size
        self.mode = isDirectory ? .directoryDefault : .regularDefault
        self.uid = 0
        self.gid = 0
        self.nlink = isDirectory ? 2 : 1
        self.atime = 0
        self.mtime = 0
        self.ctime = 0
    }

    init(_ node: VNode) {
        self.init(type: node.fileType, size: node.size, mode: node.mode,
                  uid: node.uid, gid: node.gid, nlink: node.nlink,
                  atime: node.atime, mtime: node.mtime, ctime: node.ctime)
    }
}
