/// Native implementations of pure Swiftix Go library calls.
///
/// The compiler lowers bitwise operators, byte/string conversions, `sort`, and
/// `strconv.Itoa` to `call` instructions whose reserved names start with `$`.
/// Those names never denote guest functions, so the VM dispatches them here.
/// Everything in this file is a pure function of its arguments (the `time`
/// natives take the current instant as one); heap and slice access stays in
/// the VM, and there is no process or executor state.

enum GoNative {
    /// Reserved call names handled by `GoVirtualMachine`'s pure native
    /// dispatch, with the number of operands each one pops.
    static let argumentCounts: [String: Int] = [
        "$bits.and": 2,
        "$bits.or": 2,
        "$bits.xor": 2,
        "$bits.andNot": 2,
        "$bits.shl": 2,
        "$bits.shr": 2,
        "$bits.not": 1,
        "$conv.bytesToString": 1,
        "$conv.stringToBytes": 1,
        "$conv.runeToString": 1,
        "$sort.Strings": 1,
        "$sort.Ints": 1,
        "$strconv.Itoa": 1,
        "$errors.New": 1,
        "$copy": 2,
        "$append": 3,
    ]

    /// Reserved call names of the `time` natives, with their operand counts.
    /// An instant is its nanoseconds since the Unix epoch and a duration is
    /// nanoseconds, so every operand and result is an integer or a bool.
    static let timeArgumentCounts: [String: Int] = [
        "$time.Now": 0,
        "$time.Since": 1,
        "$time.Unix": 2,
        "$time.Time.Unix": 1,
        "$time.Time.UnixMilli": 1,
        "$time.Time.UnixNano": 1,
        "$time.Time.Sub": 2,
        "$time.Time.Add": 2,
        "$time.Time.Before": 2,
        "$time.Time.After": 2,
        "$time.Time.Equal": 2,
    ]

    /// Result of the `time` native `name` when the current instant is `now`,
    /// or nil when `name` is not one. Arithmetic wraps like Go's `int64`, and
    /// seconds and milliseconds round toward negative infinity, as Go's do for
    /// instants before the epoch.
    static func time(_ name: String, _ operands: [Int64], now: Int64) -> GoValue? {
        func floored(_ value: Int64, by unit: Int64) -> Int64 {
            let quotient = value / unit
            return value % unit < 0 ? quotient - 1 : quotient
        }
        switch name {
        case "$time.Now": return .int(now)
        case "$time.Since": return .int(now &- operands[0])
        case "$time.Unix": return .int(operands[0] &* 1_000_000_000 &+ operands[1])
        case "$time.Time.Unix": return .int(floored(operands[0], by: 1_000_000_000))
        case "$time.Time.UnixMilli": return .int(floored(operands[0], by: 1_000_000))
        case "$time.Time.UnixNano": return .int(operands[0])
        case "$time.Time.Sub": return .int(operands[0] &- operands[1])
        case "$time.Time.Add": return .int(operands[0] &+ operands[1])
        case "$time.Time.Before": return .bool(operands[0] < operands[1])
        case "$time.Time.After": return .bool(operands[0] > operands[1])
        case "$time.Time.Equal": return .bool(operands[0] == operands[1])
        default: return nil
        }
    }

    /// Result of a two-operand integer operator, or nil when `name` is not one.
    /// Shifts follow Go: a negative count panics, and a count of 64 or more
    /// shifts every bit out (leaving the sign for an arithmetic right shift).
    static func integerBinary(_ name: String, _ lhs: Int64, _ rhs: Int64) throws -> Int64? {
        switch name {
        case "$bits.and": return lhs & rhs
        case "$bits.or": return lhs | rhs
        case "$bits.xor": return lhs ^ rhs
        case "$bits.andNot": return lhs & ~rhs
        case "$bits.shl":
            guard rhs >= 0 else {
                throw GoRuntimeError.panicError("runtime error: negative shift amount")
            }
            return rhs >= 64 ? 0 : lhs << rhs
        case "$bits.shr":
            guard rhs >= 0 else {
                throw GoRuntimeError.panicError("runtime error: negative shift amount")
            }
            return rhs >= 64 ? (lhs < 0 ? -1 : 0) : lhs >> rhs
        default:
            return nil
        }
    }

    /// Go's `string(b)` for a byte slice. Guest strings are always valid UTF-8,
    /// so each invalid sequence becomes U+FFFD instead of being preserved.
    static func string(fromBytes bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Go's `string(x)` for an integer: the UTF-8 encoding of the code point,
    /// or U+FFFD when `value` is not a valid Unicode scalar.
    static func string(fromCodePoint value: Int64) -> String {
        guard let narrowed = UInt32(exactly: value), let scalar = Unicode.Scalar(narrowed) else {
            return "\u{FFFD}"
        }
        return String(Character(scalar))
    }

    /// Strings in Go order, which compares UTF-8 bytes rather than Swift's
    /// canonical-equivalence ordering.
    static func sortedStrings(_ values: [String]) -> [String] {
        values
            .map { (key: Array($0.utf8), value: $0) }
            .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.value)
    }
}
