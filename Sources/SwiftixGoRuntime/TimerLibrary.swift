/// Go's `time.Timer` and `time.Ticker` at run time.
///
/// Each is the struct Go has: the channel `C` and a mark that the value came
/// from `time.NewTimer`, `time.NewTicker`, or `time.AfterFunc`. The timer of
/// `time.AfterFunc` has its function after them, in a field the type does
/// not declare, so the function lives as long as the timer does and `fmt`,
/// which prints the fields a type declares, shows what Go shows. A timer
/// that is running has an entry in the VM under the address of its struct
/// (`GoRunningTimer`); one that has fired or was stopped has none, and that
/// is all `Stop` and `Reset` report. The work scheduled on the event loop
/// cannot be withdrawn, so each arming has a sequence number and work whose
/// number is no longer the timer's does nothing.
///
/// The channel follows Go 1.23: a `Stop` or a `Reset` takes back a time that
/// was sent and not yet received, so nothing stale is received after either,
/// and both then report that the timer had not been used up. A ticker whose
/// reader is slow drops ticks; it does not queue them.
/// Pure values; no process or executor state.

/// A timer that is running.
struct GoRunningTimer: Sendable {
    /// Which arming this is. Work scheduled for an earlier one does nothing.
    let sequence: UInt64
    /// What keeps the timer's struct alive meanwhile.
    let root: Int
    /// The interval of a ticker in nanoseconds, and 0 for a timer.
    let period: Int64
    /// When it fires next, in nanoseconds of logical time.
    var deadline: Int64
}

enum GoTimers {
    /// Reserved call names of the timer natives, with the number of
    /// operands each one pops. A method's first is a pointer to the struct.
    static let argumentCounts: [String: Int] = [
        "$time.NewTimer": 1,
        "$time.NewTicker": 1,
        "$time.AfterFunc": 2,
        "$time.Timer.Stop": 1,
        "$time.Timer.Reset": 2,
        "$time.Ticker.Stop": 1,
        "$time.Ticker.Reset": 2,
    ]

    static let timerTypeName = "time.Timer"
    static let tickerTypeName = "time.Ticker"

    // What Go panics with, each a string.
    static let nonPositiveTicker = "non-positive interval for NewTicker"
    static let nonPositiveReset = "non-positive interval for Ticker.Reset"
    static func uninitialized(_ method: String, _ type: String) -> String {
        "time: \(method) called on uninitialized \(type)"
    }

    /// How many fields the types declare: the channel and the mark.
    static let declaredFieldCount = 2

    /// The struct of a timer or a ticker that one of the constructors made:
    /// with a channel, or with the function of `time.AfterFunc`, which has
    /// none.
    static func value(typeName: String, channel: GoValue, function: GoValue? = nil) -> GoValue {
        var fields = [
            GoStructFieldValue(name: "C", value: channel),
            GoStructFieldValue(
                name: typeName == tickerTypeName ? "initTicker" : "initTimer", value: .bool(true)),
        ]
        if let function { fields.append(GoStructFieldValue(name: "f", value: function)) }
        return .structure(GoStructValue(typeName: typeName, fields: fields))
    }

    /// The channel of the timer struct `value`, whether a constructor made
    /// it, and the function it calls when it is the timer of
    /// `time.AfterFunc`; nil when `value` is no such struct.
    static func fields(
        of value: GoValue
    ) -> (channel: GoValue, isInitialized: Bool, function: GoValue?)? {
        guard case .structure(let timer) = value, timer.fields.count >= declaredFieldCount,
            case .bool(let isInitialized) = timer.fields[1].value
        else { return nil }
        return (
            timer.fields[0].value, isInitialized,
            timer.fields.count > declaredFieldCount ? timer.fields[declaredFieldCount].value : nil
        )
    }

    /// When a ticker that was due at `deadline` and fired at `now` is due
    /// next: the first multiple of its period after `now`, as Go computes
    /// it, so a ticker that fell behind skips the ticks it missed.
    static func nextDeadline(after deadline: Int64, period: Int64, now: Int64) -> Int64 {
        let late = max(0, now &- deadline)
        let (step, overflow) = period.multipliedReportingOverflow(by: 1 + late / period)
        let (next, overflowed) = deadline.addingReportingOverflow(step)
        return overflow || overflowed ? .max : next
    }
}
