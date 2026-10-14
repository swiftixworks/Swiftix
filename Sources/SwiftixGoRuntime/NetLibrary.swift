/// The natives of `net`, whose types and errors are Go text of the library
/// (`GoNetLibrary` in `SwiftixGo`).
///
/// Each native names a connection or a listener by the number of its
/// descriptor and reports what went wrong as a code, which the text turns
/// into Go's error: a `*net.OpError` around `os.ErrDeadlineExceeded`,
/// `net.ErrClosed`, or the failed system call. The VM keeps, for each
/// connection in use, its deadlines and what it has received
/// (`GoNetConnectionState`). Constants and reference state of one run; no
/// process state.
enum GoNetNatives {
    /// Reserved call names, with the number of operands each pops.
    static let argumentCounts: [String: Int] = [
        "$net.listen": 2,
        "$net.accept": 1,
        "$net.dial": 2,
        "$net.read": 2,
        "$net.write": 2,
        "$net.close": 1,
        "$net.deadline": 3,
    ]

    // The codes, as `net.go` declares them.
    static let success: Int64 = 0
    static let endOfFile: Int64 = 1
    static let timeout: Int64 = 2
    static let closed: Int64 = 3
    static let refused: Int64 = 4
    static let addressInUse: Int64 = 5
    static let unavailable: Int64 = 6
    static let reset: Int64 = 7
    static let timedOut: Int64 = 8
    static let noAddress: Int64 = 9

    /// What `$net.deadline` sets, as bits.
    static let readDeadline: Int64 = 1
    static let writeDeadline: Int64 = 2
    /// The deadline that stands for none: the zero time.
    static let noDeadline = Int64.min

    /// The first port tried for a listener on port 0, below the kernel's
    /// ephemeral ports, which its connections take.
    static let firstChosenPort: UInt16 = 40_000
}

/// A goroutine parked in `Read` of a connection.
final class GoNetReader {
    /// Where the bytes go.
    let buffer: GoSliceValue
    /// The wait that a close of the descriptor ends, with the goroutine.
    let wait: GoParkedNetWait
    /// The read deadline the reader was parked under, in Unix nanoseconds;
    /// a timer armed for another does nothing.
    var deadline: Int64?

    init(buffer: GoSliceValue, wait: GoParkedNetWait, deadline: Int64?) {
        self.buffer = buffer
        self.wait = wait
        self.deadline = deadline
    }
}

/// A connection's deadlines and what it has received.
///
/// The kernel's receive cannot be withdrawn, so one whose reader timed out
/// stays outstanding, and what it brings is kept for the next `Read`: a
/// connection stays usable after its deadline passed, as in Go.
final class GoNetConnectionState {
    var readDeadline: Int64?
    var writeDeadline: Int64?
    /// Bytes received and not yet read, and whether the peer has finished.
    var received: [UInt8] = []
    var sawEnd = false
    /// Whether a receive of the kernel is outstanding.
    var receiving = false
    /// The goroutines that wait in `Read`, first come first served.
    var readers: [GoNetReader] = []
}
