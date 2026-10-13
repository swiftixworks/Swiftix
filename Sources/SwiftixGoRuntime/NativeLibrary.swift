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
        "$new": 1,
        "$clear": 2,
        "$append": 3,
        "$strings.ToUpper": 1,
        "$strings.ToLower": 1,
        "$strings.Fields": 1,
        "$strings.TrimPrefix": 2,
        "$strings.TrimSuffix": 2,
    ]

    /// Reserved call names of the `time` natives, with their operand counts.
    /// An instant is its nanoseconds since the Unix epoch and a duration is
    /// nanoseconds, so every operand is an integer, and every result an
    /// integer, a bool, or the text of a duration.
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
        "$time.Until": 1,
        "$time.Duration.String": 1,
        "$time.Duration.Nanoseconds": 1,
        "$time.Duration.Microseconds": 1,
        "$time.Duration.Milliseconds": 1,
        "$time.Duration.Round": 2,
        "$time.Duration.Truncate": 2,
        "$time.Duration.Abs": 1,
    ]

    /// Reserved call names of the natives the library's own Go text calls
    /// for a slice of any element type, with their operand counts: the
    /// length of the slice an `any` holds, and the exchange of two of its
    /// elements.
    static let sliceArgumentCounts: [String: Int] = [
        "$sort.length": 2,
        "$sort.swap": 3,
    ]

    /// Go's name for the kind of `type`, as `reflect` puts it in a panic:
    /// `int`, `struct`, `ptr`. A value without a type is the zero `Value`.
    static func kindName(of type: GoRuntimeType?) -> String {
        switch type {
        case nil: return "zero"
        case .integer?: return "int"
        case .byte?: return "uint8"
        case .string?: return "string"
        case .boolean?: return "bool"
        case .error?, .interface?: return "interface"
        case .slice?: return "slice"
        case .array?: return "array"
        case .map?: return "map"
        case .pointer?: return "ptr"
        case .channel?: return "chan"
        case .structure?, .named?: return "struct"
        case .other(let text)?: return text.hasPrefix("func") ? "func" : "struct"
        }
    }

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
        default: return duration(name, operands, now: now)
        }
    }

    /// Result of a two-operand integer operator, or nil when `name` is not one.
    /// Prefix of the call that starts a new variable in a local of the
    /// executing frame: `$fresh.<index>` unbinds the local from its cell, so
    /// the store that follows allocates one and pointers to the old cell
    /// keep the old variable.
    static let freshLocalPrefix = "$fresh."

    /// The local a `$fresh.<index>` call names, or nil for any other name.
    static func freshLocal(_ name: String) -> Int? {
        guard name.hasPrefix(freshLocalPrefix) else { return nil }
        return Int(name.dropFirst(freshLocalPrefix.utf8.count))
    }

    /// Prefix of the call that makes a local of the executing frame the
    /// variable a pointer points to: `$bind.<index>`, with the pointer as
    /// its operand. A function literal names the variables it captures so.
    static let boundLocalPrefix = "$bind."

    /// The local a `$bind.<index>` call names, or nil for any other name.
    static func boundLocal(_ name: String) -> Int? {
        guard name.hasPrefix(boundLocalPrefix) else { return nil }
        return Int(name.dropFirst(boundLocalPrefix.utf8.count))
    }

    /// The call through a function value, which is its first operand.
    static let callFunctionValue = "$call"

    /// The call that panics when its operand is nil and does nothing else.
    static let requireValue = "$nonnil"

    /// Prefix of the call that makes the executing frame return what its
    /// result variables hold when it ends, after its deferred calls have
    /// run: `$results.<local>.<local>`, the locals of the results in order.
    static let liveResultsPrefix = "$results."

    /// The locals a `$results.` call names, or nil for any other name.
    static func resultLocals(_ name: String) -> [Int]? {
        guard name.hasPrefix(liveResultsPrefix) else { return nil }
        let locals = name.dropFirst(liveResultsPrefix.utf8.count).split(separator: ".").map { Int($0) }
        return locals.contains(nil) ? nil : locals.compactMap { $0 }
    }

    /// The type name of a function value: a struct whose first field names
    /// the function and whose others are passed to it before the arguments
    /// of a call. `GoValue` has no case for a function.
    static let functionValueTypeName = "$func"

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
                throw GoRuntimePanic.negativeShift
            }
            return rhs >= 64 ? 0 : lhs << rhs
        case "$bits.shr":
            guard rhs >= 0 else {
                throw GoRuntimePanic.negativeShift
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
