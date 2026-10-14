/// The natives of `os/signal` and of `syscall`'s signals. The library's
/// text keeps Go's bookkeeping of which channel wants which signal; the VM
/// only installs a handler with the kernel for a signal a program asks for,
/// keeps what arrives, and hands it to the goroutine of `os/signal` that
/// waits for the next one.
enum GoSignals {
    /// Reserved call names, with the number of operands each one pops.
    static let argumentCounts: [String: Int] = [
        "$signal.enable": 1,
        "$signal.ignore": 1,
        "$signal.reset": 1,
        "$signal.wait": 0,
        "$syscall.kill": 2,
        "$syscall.getpid": 0,
    ]
}

/// A program ended by a signal its process did not handle, as a process of
/// Go's ends: no deferred call runs, and `go run` reports the signal
/// (`signal: terminated`) and fails.
public struct GoSignalTermination: Error, Sendable, Equatable, CustomStringConvertible {
    public let signal: Int32

    public init(signal: Int32) {
        self.signal = signal
    }

    public var description: String { "signal: " + Self.name(of: signal) }

    /// Whether Linux ends a process that does not handle `signal`.
    static func terminates(_ signal: Int64) -> Bool {
        [1, 2, 3, 9, 10, 12, 13, 14, 15].contains(signal)
    }

    /// The text `syscall.Signal` has for `signal`, as Linux words it.
    static func name(of signal: Int32) -> String {
        switch signal {
        case 1: return "hangup"
        case 2: return "interrupt"
        case 3: return "quit"
        case 9: return "killed"
        case 10: return "user defined signal 1"
        case 12: return "user defined signal 2"
        case 13: return "broken pipe"
        case 14: return "alarm clock"
        case 15: return "terminated"
        case 17: return "child exited"
        case 18: return "continued"
        case 19: return "stopped (signal)"
        case 20: return "stopped"
        default: return "signal \(signal)"
        }
    }
}
