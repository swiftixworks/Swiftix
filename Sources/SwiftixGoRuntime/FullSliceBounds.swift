/// The bounds of a full slice expression `a[low:high:max]`, tested in Go's
/// order with Go's text: `max` against the capacity (the length of an
/// array), then `high` against `max`, then `low` against `high`. A negative
/// bound fails the first test it is in.
enum GoFullSliceBounds {
    static func check(_ low: Int64, _ high: Int64, _ max: Int64, capacity: Int, isArray: Bool) throws {
        let text: String
        if max < 0 {
            text = "[::\(max)]"
        } else if max > Int64(capacity) {
            text = "[::\(max)] with \(isArray ? "length" : "capacity") \(capacity)"
        } else if high < 0 {
            text = "[:\(high):]"
        } else if high > max {
            text = "[:\(high):\(max)]"
        } else if low < 0 {
            text = "[\(low)::]"
        } else if low > high {
            text = "[\(low):\(high):]"
        } else {
            return
        }
        throw GoRuntimePanic(
            GoErrors.boundsErrorType, "runtime error: slice bounds out of range " + text)
    }
}
