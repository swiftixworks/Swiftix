/// Pure helpers behind the Swiftix Go `os` file surface: open-flag decoding,
/// path splitting, and Go's wording for a failed system call.
///
/// The VM makes the system calls. Nothing here touches a process, the heap, or
/// executor state.

import Swiftix

enum GoFiles {
    /// Reserved call names of the file natives `GoVirtualMachine` runs, with
    /// the number of operands each one pops (the `*os.File` receiver first).
    static let argumentCounts: [String: Int] = [
        "$os.Open": 1,
        "$os.Create": 1,
        "$os.OpenFile": 3,
        "$os.Remove": 1,
        "$os.Rename": 2,
        "$os.Mkdir": 2,
        "$os.File.ReadAt": 3,
        "$os.File.WriteAt": 3,
        "$os.File.Seek": 3,
        "$os.File.Close": 1,
        "$os.File.Sync": 1,
    ]

    // Go's `os.O_*` values on Linux, which the compiler emits as constants.
    static let accessMask: Int64 = 0o3
    static let readOnly: Int64 = 0
    static let writeOnly: Int64 = 1
    static let readWrite: Int64 = 2
    static let create: Int64 = 0o100
    static let exclusive: Int64 = 0o200
    static let truncate: Int64 = 0o1000
    static let append: Int64 = 0o2000

    /// Message of `io.EOF`.
    static let endOfFile = "EOF"
    /// Message of `os.ErrClosed`, for a file used after `Close`.
    static let closedFile = "file already closed"
    /// Message of `os.ErrInvalid`, for a nil `*os.File`.
    static let invalidFile = "invalid argument"

    /// First `*os.File` handle of a file the program opens. Smaller values
    /// are descriptor numbers, which is what `os.Stdin`, `os.Stdout`, and
    /// `os.Stderr` are.
    static let firstHandle: Int64 = 1 << 32

    /// What a `*os.File` value denotes.
    struct OpenFile {
        /// Path the file was opened with, for Go's error wording.
        let name: String
        let descriptor: Int
        /// Opened with `O_APPEND`, which Go refuses to combine with `WriteAt`.
        let appends: Bool
    }

    /// The file a descriptor number denotes without having been opened by
    /// the program.
    static func inherited(_ descriptor: Int) -> OpenFile {
        let name: String
        switch descriptor {
        case 0: name = "/dev/stdin"
        case 1: name = "/dev/stdout"
        case 2: name = "/dev/stderr"
        default: name = "/dev/fd/\(descriptor)"
        }
        return OpenFile(name: name, descriptor: descriptor, appends: false)
    }

    /// The kernel open flags and access mode Go `flag` asks for, or nil when
    /// it names no access mode or sets a bit this runtime does not implement.
    static func openMode(_ flag: Int64) -> (flags: OpenFlags, access: FileAccessMode)? {
        let known = accessMask | create | exclusive | truncate | append
        guard flag >= 0, flag & ~known == 0 else { return nil }
        let access: FileAccessMode
        switch flag & accessMask {
        case readOnly: access = .readOnly
        case writeOnly: access = .writeOnly
        case readWrite: access = .readWrite
        default: return nil
        }
        var flags: OpenFlags = []
        if flag & create != 0 { flags.insert(.create) }
        if flag & exclusive != 0 { flags.insert(.exclusive) }
        if flag & truncate != 0 { flags.insert(.truncate) }
        if flag & append != 0 { flags.insert(.append) }
        return (flags, access)
    }

    /// Go's text for a failed system call (`syscall.Errno.Error()` on Linux).
    static func message(for error: Error) -> String {
        guard let error = error as? SyscallError else { return "input/output error" }
        switch error {
        case .noSuchFileOrDirectory: return "no such file or directory"
        case .badFileDescriptor: return "bad file descriptor"
        case .interrupted: return "interrupted system call"
        case .inputOutput: return "input/output error"
        case .wouldBlock: return "resource temporarily unavailable"
        case .noChildProcess: return "no child processes"
        case .isADirectory: return "is a directory"
        case .notADirectory: return "not a directory"
        case .directoryNotEmpty: return "directory not empty"
        case .brokenPipe: return "broken pipe"
        case .fileExists: return "file exists"
        case .noSuchDevice: return "no such device"
        case .connectionReset: return "connection reset by peer"
        case .notConnected: return "transport endpoint is not connected"
        case .invalidArgument: return "invalid argument"
        case .noSpace: return "no space left on device"
        case .readOnlyFileSystem: return "read-only file system"
        case .permissionDenied, .capabilityViolation: return "permission denied"
        }
    }

    /// The parent directory and final component of `path` after resolving it
    /// against `workingDirectory` and collapsing `.` and `..`, or nil when it
    /// names the root.
    static func split(
        _ path: String,
        workingDirectory: String
    ) -> (parent: String, name: String)? {
        let joined =
            path.hasPrefix("/")
            ? path
            : (workingDirectory.hasSuffix("/") ? workingDirectory : workingDirectory + "/") + path
        var components: [Substring] = []
        for part in joined.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(part)
            }
        }
        guard let name = components.popLast() else { return nil }
        return ("/" + components.joined(separator: "/"), String(name))
    }
}
