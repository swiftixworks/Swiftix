/// Run-time errors of a guest program that Go reports as panics.
///
/// A nil pointer dereference, an index or a slice bound out of range, an
/// integer division by zero, and the like do not end a Go program at once:
/// they panic, deferred functions run, and `recover` returns a value that is
/// an `error` with the text below. An instruction that meets one throws a
/// `GoRuntimePanic`; the VM turns it into a panic of the frame that was
/// executing. A fault of the VM itself, such as a dangling heap cell or a
/// malformed image, stays a `GoRuntimeError` and ends the run.
///
/// The value of such a panic is an interface value whose type name is one of
/// Go's runtime error types and whose value is the message: no heap cell is
/// allocated to report a failure, and two of them compare as Go's do, by
/// what they say. Pure values; no process or executor state.

struct GoRuntimePanic: Error, Equatable, Sendable {
    /// What `recover` returns.
    let value: GoValue
    /// What Go prints after `panic: ` when nothing recovers it.
    let message: String

    /// A panic with an error of one of the runtime's types.
    init(_ typeName: String, _ message: String) {
        value = .interface(GoInterfaceValue(typeName: typeName, value: .string(message)))
        self.message = message
    }

    /// A panic with a string, as a library function raises one.
    init(text: String) {
        value = .string(text)
        message = text
    }

    private static let prefix = "runtime error: "

    static let nilDereference = GoRuntimePanic(
        GoErrors.runtimeErrorType, prefix + "invalid memory address or nil pointer dereference")
    static let divideByZero = GoRuntimePanic(
        GoErrors.runtimeErrorType, prefix + "integer divide by zero")
    static let negativeShift = GoRuntimePanic(
        GoErrors.runtimeErrorType, prefix + "negative shift amount")
    static let makeSliceLength = GoRuntimePanic(
        GoErrors.runtimeErrorType, prefix + "makeslice: len out of range")
    static let makeSliceCapacity = GoRuntimePanic(
        GoErrors.runtimeErrorType, prefix + "makeslice: cap out of range")
    static let nilMapAssignment = GoRuntimePanic(
        GoErrors.plainRuntimeErrorType, "assignment to entry in nil map")
    static let closedChannelSend = GoRuntimePanic(
        GoErrors.plainRuntimeErrorType, "send on closed channel")

    /// `x[index]` where `x` has `length` elements.
    static func index(_ index: Int, length: Int) -> GoRuntimePanic {
        GoRuntimePanic(
            GoErrors.boundsErrorType,
            prefix + "index out of range [\(index)]" + (index < 0 ? "" : " with length \(length)"))
    }

    /// `x[low:high]`, or nil when the bounds are in range. `limit` is the
    /// capacity of a slice and the length of a string or an array, and Go
    /// tests the high bound against it before it compares the two bounds.
    static func slice(
        low: Int,
        high: Int,
        limit: Int,
        limitIsCapacity: Bool
    ) -> GoRuntimePanic? {
        let text: String
        if high < 0 {
            text = "[:\(high)]"
        } else if high > limit {
            text = "[:\(high)] with \(limitIsCapacity ? "capacity" : "length") \(limit)"
        } else if low < 0 {
            text = "[\(low):]"
        } else if low > high {
            text = "[\(low):\(high)]"
        } else {
            return nil
        }
        return GoRuntimePanic(GoErrors.boundsErrorType, prefix + "slice bounds out of range " + text)
    }
}
