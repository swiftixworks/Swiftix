/// The structured status a parent observes for a child process.
///
/// POSIX wait status packs these cases into bits. Swiftix keeps the semantic
/// shape explicit, while `code` preserves the shell-visible convention used by
/// existing commands (`128 + signal` for signal and stop notifications).
public enum ProcessWaitStatus: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    case stopped(Int32)

    public var code: Int32 {
        switch self {
        case .exited(let code):
            return code
        case .signaled(let signal), .stopped(let signal):
            return 128 &+ signal
        }
    }

    public var isStopped: Bool {
        if case .stopped = self { return true }
        return false
    }

    public var exitCode: Int32? {
        if case .exited(let code) = self { return code }
        return nil
    }

    public var terminatingSignal: Int32? {
        if case .signaled(let signal) = self { return signal }
        return nil
    }

    public var stoppingSignal: Int32? {
        if case .stopped(let signal) = self { return signal }
        return nil
    }
}

/// One waitable child-state transition observed by a parent.
public struct ChildWaitEvent: Sendable, Equatable {
    public let childPID: PID
    public let status: ProcessWaitStatus

    public init(childPID: PID, status: ProcessWaitStatus) {
        self.childPID = childPID
        self.status = status
    }

    public var code: Int32 { status.code }
    public var isStopped: Bool { status.isStopped }
}

/// Options for Linux-like child waiting.
///
/// `noHang` mirrors `WNOHANG`: if matching children exist but none have a
/// waitable event, `waitpid` returns `.success(nil)`. `untraced` mirrors
/// `WUNTRACED`: stopped children are returned as `.stopped` events instead of
/// being left queued for job control.
public struct ProcessWaitOptions: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let noHang = ProcessWaitOptions(rawValue: 1 << 0)
    public static let untraced = ProcessWaitOptions(rawValue: 1 << 1)
}
