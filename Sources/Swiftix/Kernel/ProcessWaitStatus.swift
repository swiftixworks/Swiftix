/// A terminal process result. Kept separate from stop/continue notifications so
/// an exited process can never be represented as a "stopped zombie".
public enum ProcessExitStatus: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    public var code: Int32 {
        switch self {
        case .exited(let code):
            return code
        case .signaled(let signal):
            return 128 &+ signal
        }
    }

    public var exitCode: Int32? {
        if case .exited(let code) = self { return code }
        return nil
    }

    public var terminatingSignal: Int32? {
        if case .signaled(let signal) = self { return signal }
        return nil
    }

    var waitStatus: ProcessWaitStatus {
        switch self {
        case .exited(let code): return .exited(code)
        case .signaled(let signal): return .signaled(signal)
        }
    }
}

/// One structured child-state change observed by a parent.
///
/// POSIX wait status packs these cases into bits. Swiftix keeps the semantic
/// shape explicit, while `code` preserves the shell-visible convention used by
/// existing commands (`128 + signal` for signal and stop notifications).
public enum ProcessWaitStatus: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    case stopped(Int32)
    case continued

    public var code: Int32 {
        switch self {
        case .exited(let code):
            return code
        case .signaled(let signal), .stopped(let signal):
            return 128 &+ signal
        case .continued:
            return 0
        }
    }

    public var isStopped: Bool {
        if case .stopped = self { return true }
        return false
    }

    public var isContinued: Bool {
        self == .continued
    }

    public var isTerminated: Bool {
        switch self {
        case .exited, .signaled: return true
        case .stopped, .continued: return false
        }
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

    var exitStatus: ProcessExitStatus? {
        switch self {
        case .exited(let code): return .exited(code)
        case .signaled(let signal): return .signaled(signal)
        case .stopped, .continued: return nil
        }
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
    public var isContinued: Bool { status.isContinued }
}

/// Options for Linux-like child waiting.
///
/// `noHang` mirrors `WNOHANG`: if matching children exist but none have a
/// waitable event, `waitpid` returns `.success(nil)`. `untraced` mirrors
/// `WUNTRACED`; `continued` mirrors `WCONTINUED`.
public struct ProcessWaitOptions: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let noHang = ProcessWaitOptions(rawValue: 1 << 0)
    public static let untraced = ProcessWaitOptions(rawValue: 1 << 1)
    public static let continued = ProcessWaitOptions(rawValue: 1 << 2)
}
