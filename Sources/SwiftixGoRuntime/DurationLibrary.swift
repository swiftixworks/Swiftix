/// Go's `time.Duration` at run time: a count of nanoseconds in an `int`.
///
/// `GoDuration` is the arithmetic and the text of the type, transcribed from
/// Go's `time` package so that every value prints, rounds, and parses as it
/// does there. `GoLibraryMethods` makes the methods of the type functions of
/// every program: the compiler calls a method it can see by its reserved
/// native name, and what finds a method by the name of the dynamic type (a
/// call through an interface, a method value, a panic that is reported)
/// finds one of these, as it finds a method the program declared. `fmt`
/// alone does not call one: it asks for the text. Pure functions of their
/// arguments; no process or executor state.

enum GoDuration {
    /// Go's `Duration.Seconds`, `Minutes`, and `Hours`: the duration in
    /// units of `unit` nanoseconds, as the bits of a `float64`. The whole
    /// units and the rest are converted apart, as Go converts them, so a
    /// long duration keeps what a single division would round away.
    static func units(_ duration: Int64, _ unit: Int64) -> GoValue {
        let value = Double(duration / unit) + Double(duration % unit) / Double(unit)
        return .int(Int64(bitPattern: value.bitPattern))
    }

    static let nanosecond: Int64 = 1
    static let microsecond: Int64 = 1_000
    static let millisecond: Int64 = 1_000_000
    static let second: Int64 = 1_000_000_000
    static let minute: Int64 = 60 * second
    static let hour: Int64 = 60 * minute

    /// Go's `Duration.String`: `1h2m3.5s`, with the largest unit first and
    /// no unit that is zero before it; below one second a single unit,
    /// `1.5ms`, `2µs`, `3ns`; and `0s` for zero.
    static func string(_ duration: Int64) -> String {
        // The largest is 2562047h47m16.854775808s, with a sign before it.
        var digits: [UInt8] = []
        var magnitude = duration.magnitude

        /// Go's `fmtFrac`: the last `precision` decimal digits of
        /// `magnitude` as a fraction, without trailing zeros, and without
        /// the point when nothing is left. The text is built backwards.
        func fraction(_ precision: Int) {
            var printing = false
            for _ in 0..<precision {
                let digit = UInt8(magnitude % 10)
                printing = printing || digit != 0
                if printing { digits.append(digit + 0x30) }
                magnitude /= 10
            }
            if printing { digits.append(UInt8(ascii: ".")) }
        }
        /// Go's `fmtInt`: `value` in decimal, `0` for zero.
        func integer(_ value: UInt64) {
            var value = value
            repeat {
                digits.append(UInt8(value % 10) + 0x30)
                value /= 10
            } while value > 0
        }

        if magnitude < UInt64(second) {
            digits.append(UInt8(ascii: "s"))
            if magnitude == 0 {
                return "0s"
            } else if magnitude < UInt64(microsecond) {
                digits.append(UInt8(ascii: "n"))
                fraction(0)
            } else if magnitude < UInt64(millisecond) {
                // U+00B5, the micro sign, as Go writes it: C2 B5.
                digits.append(contentsOf: [0xB5, 0xC2])
                fraction(3)
            } else {
                digits.append(UInt8(ascii: "m"))
                fraction(6)
            }
            integer(magnitude)
        } else {
            digits.append(UInt8(ascii: "s"))
            fraction(9)
            // What is left is whole seconds, then minutes, then hours. Go
            // stops there: a day has no fixed length.
            integer(magnitude % 60)
            magnitude /= 60
            if magnitude > 0 {
                digits.append(UInt8(ascii: "m"))
                integer(magnitude % 60)
                magnitude /= 60
                if magnitude > 0 {
                    digits.append(UInt8(ascii: "h"))
                    integer(magnitude)
                }
            }
        }
        if duration < 0 { digits.append(UInt8(ascii: "-")) }
        return String(decoding: digits.reversed(), as: UTF8.self)
    }

    /// Go's `Duration.Truncate`: `duration` rounded toward zero to a
    /// multiple of `unit`, or itself when `unit` is not positive.
    static func truncate(_ duration: Int64, _ unit: Int64) -> Int64 {
        unit <= 0 ? duration : duration - duration % unit
    }

    /// Go's `Duration.Round`: the nearest multiple of `unit`, halves away
    /// from zero, the largest or smallest duration when that cannot be
    /// represented, and `duration` itself when `unit` is not positive.
    static func round(_ duration: Int64, _ unit: Int64) -> Int64 {
        guard unit > 0 else { return duration }
        var remainder = duration % unit
        func lessThanHalf(_ part: Int64) -> Bool {
            UInt64(bitPattern: part) &+ UInt64(bitPattern: part) < UInt64(bitPattern: unit)
        }
        if duration < 0 {
            remainder = -remainder
            if lessThanHalf(remainder) { return duration + remainder }
            let rounded = duration &- unit &+ remainder
            return rounded < duration ? rounded : .min
        }
        if lessThanHalf(remainder) { return duration - remainder }
        let rounded = duration &+ unit &- remainder
        return rounded > duration ? rounded : .max
    }

    /// Go's `Duration.Abs`, where the smallest duration becomes the largest.
    static func absolute(_ duration: Int64) -> Int64 {
        duration == .min ? .max : (duration < 0 ? -duration : duration)
    }

    /// Go's `time.ParseDuration`: a sign, then numbers with a unit each,
    /// `1h30m`, `1.5s`, `-250ms`. The error is the one Go reports.
    static func parse(_ text: String) -> (duration: Int64, error: String?) {
        let invalid: (Int64, String?) = (0, "time: invalid duration " + quote(text))
        var rest = Array(text.utf8)[...]
        var negative = false
        if let sign = rest.first, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") {
            negative = sign == UInt8(ascii: "-")
            rest = rest.dropFirst()
        }
        if rest.elementsEqual([UInt8(ascii: "0")]) { return (0, nil) }
        if rest.isEmpty { return invalid }

        let limit = UInt64(1) << 63
        func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
        var total: UInt64 = 0
        while let first = rest.first {
            guard first == UInt8(ascii: ".") || isDigit(first) else { return invalid }
            // The digits before the point.
            var whole: UInt64 = 0
            let before = rest.count
            while let digit = rest.first, isDigit(digit) {
                guard whole <= limit / 10 else { return invalid }
                whole = whole * 10 + UInt64(digit - 0x30)
                guard whole <= limit else { return invalid }
                rest = rest.dropFirst()
            }
            let hasWhole = rest.count != before
            // The digits after it. Past what an integer holds they add no
            // precision and are passed over, as Go passes over them.
            var part: UInt64 = 0
            var scale = 1.0
            var hasPart = false
            if rest.first == UInt8(ascii: ".") {
                rest = rest.dropFirst()
                var overflowed = false
                while let digit = rest.first, isDigit(digit) {
                    rest = rest.dropFirst()
                    hasPart = true
                    if overflowed { continue }
                    if part > (limit - 1) / 10 {
                        overflowed = true
                        continue
                    }
                    let next = part * 10 + UInt64(digit - 0x30)
                    if next > limit {
                        overflowed = true
                        continue
                    }
                    part = next
                    scale *= 10
                }
            }
            guard hasWhole || hasPart else { return invalid }

            let unitBytes = rest.prefix { $0 != UInt8(ascii: ".") && !isDigit($0) }
            guard !unitBytes.isEmpty else {
                return (0, "time: missing unit in duration " + quote(text))
            }
            rest = rest.dropFirst(unitBytes.count)
            let unitName = String(decoding: unitBytes, as: UTF8.self)
            let unit: UInt64
            switch unitName {
            case "ns": unit = UInt64(nanosecond)
            // The micro sign U+00B5 and the Greek letter mu U+03BC.
            case "us", "\u{B5}s", "\u{3BC}s": unit = UInt64(microsecond)
            case "ms": unit = UInt64(millisecond)
            case "s": unit = UInt64(second)
            case "m": unit = UInt64(minute)
            case "h": unit = UInt64(hour)
            default:
                return (
                    0, "time: unknown unit " + quote(unitName) + " in duration " + quote(text)
                )
            }
            guard whole <= limit / unit else { return invalid }
            whole *= unit
            if part > 0 {
                // Go computes the fraction in floating point, which is exact
                // to the nanosecond for a fraction of an hour. It is at most
                // one unit, so it is in range.
                whole = whole &+ UInt64(Double(part) * (Double(unit) / scale))
                guard whole <= limit else { return invalid }
            }
            // Go's unsigned sum wraps, and so does this one.
            total = total &+ whole
            guard total <= limit else { return invalid }
        }
        if negative { return (Int64(bitPattern: 0 &- total), nil) }
        guard total <= limit - 1 else { return invalid }
        return (Int64(total), nil)
    }

    /// The `quote` of Go's `time` package: a string in double quotes with
    /// `"` and `\` escaped, and every byte of a control or non-ASCII
    /// character as `\x` and two hexadecimal digits.
    static func quote(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x80 || scalar.value < 0x20 {
                for byte in String(scalar).utf8 {
                    let hex = String(byte, radix: 16)
                    quoted += "\\x" + (hex.count == 1 ? "0" + hex : hex)
                }
            } else {
                if scalar == "\"" || scalar == "\\" { quoted += "\\" }
                quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}

extension GoNative {
    /// Call name of `time.ParseDuration`, the one `time` native that takes
    /// a string and gives an error.
    static let parseDuration = "$time.ParseDuration"

    /// Result of the `time` native `name` that takes or gives a duration,
    /// or nil when `name` is not one. A `float64` result is its bits.
    static func duration(_ name: String, _ operands: [Int64], now: Int64) -> GoValue? {
        switch name {
        case "$time.Until": return .int(operands[0] &- now)
        case "$time.Duration.String": return .string(GoDuration.string(operands[0]))
        case "$time.Duration.Nanoseconds": return .int(operands[0])
        case "$time.Duration.Microseconds": return .int(operands[0] / GoDuration.microsecond)
        case "$time.Duration.Milliseconds": return .int(operands[0] / GoDuration.millisecond)
        case "$time.Duration.Round": return .int(GoDuration.round(operands[0], operands[1]))
        case "$time.Duration.Truncate": return .int(GoDuration.truncate(operands[0], operands[1]))
        case "$time.Duration.Abs": return .int(GoDuration.absolute(operands[0]))
        case "$time.Duration.Seconds": return GoDuration.units(operands[0], 1_000_000_000)
        case "$time.Duration.Minutes": return GoDuration.units(operands[0], 60 * 1_000_000_000)
        case "$time.Duration.Hours": return GoDuration.units(operands[0], 3_600 * 1_000_000_000)
        default: return nil
        }
    }
}

/// The methods of library types as functions of every program.
///
/// A defined type of the library, `time.Duration`, is at run time what a
/// defined type of the program is: a name with an underlying type, in the
/// descriptor an interface value carries. Its methods are looked up the same
/// way, as functions named `<type>.<method>`, and these are the functions:
/// each loads its operands and makes the reserved native call of the method.
/// A missing method, an assertion to an interface, and a panic's report
/// therefore need nothing of their own for a library type.
/// They are no part of an image, so an image that boxes no such value is
/// what it was, and one that does needs a runtime that has them.
enum GoLibraryMethods {
    static let durationTypeName = "time.Duration"

    /// The functions, by the name a method of a program type would have.
    static let functions: [String: GoBytecodeFunction] = {
        var functions: [String: GoBytecodeFunction] = [:]
        for (native, operandCount) in GoNative.timeArgumentCounts {
            let prefix = "$" + durationTypeName + "."
            guard native.hasPrefix(prefix) else { continue }
            let name = String(native.dropFirst())
            functions[name] = GoBytecodeFunction(
                name: name,
                parameterCount: operandCount,
                returnCount: 1,
                localCount: operandCount,
                instructions: (0..<operandCount).map(GoInstruction.load)
                    + [.call(native, argumentCount: operandCount), .returnValues(count: 1)])
        }
        // And those of the handles: a connection, a listener, a file.
        functions.merge(handleFunctions) { first, _ in first }
        return functions
    }()

    /// What `fmt` prints for a value of the dynamic type `owner` (`T` or
    /// `*T`) under a verb for text, when `owner` is a library type: the
    /// result of its `String` method, computed here. `fmt` would get the
    /// same from the function above, at the price of a frame and of
    /// formatting its operands again for every value printed. A nil
    /// pointer prints as `<nil>`, as for a method a program declared on the
    /// value. Nil for a type of the program, and for a value that is not
    /// what the type holds.
    static func text(
        of value: GoValue, owner: String, read: (GoPointer) throws -> GoValue
    ) throws -> String? {
        guard owner == durationTypeName || owner == "*" + durationTypeName else { return nil }
        var held = value
        if owner.hasPrefix("*") {
            if value == .nilValue { return GoFormat.nilText }
            guard case .pointer(let pointer) = value else { return nil }
            held = try read(pointer)
        }
        guard case .int(let nanoseconds) = held else { return nil }
        return GoDuration.string(nanoseconds)
    }

    /// Mark of a line among the implementers of an interface target that
    /// names a library type which does not implement it. The VM keeps no
    /// method types: a library type has the methods of an interface when it
    /// has one of each name with as many parameters and results, unless the
    /// compiler, which knows the types, wrote this line.
    static let refusalMark = "!"

    /// Whether the dynamic type `owner` (`T` or `*T`) is a library type
    /// that implements `target`.
    static func implements(_ owner: String, _ target: GoErrors.InterfaceTarget) -> Bool {
        if GoLibraryStructMethods.implements(owner, target) { return true }
        guard isLibraryType(owner), !target.methods.isEmpty else { return false }
        // A handle type is an interface with one type that implements it.
        if let only = handleInterfaces[target.typeName] { return owner == only }
        // A pointer to a duration has the methods of a duration.
        let base = owner == "*" + durationTypeName ? durationTypeName : owner
        guard !target.implementers.contains(refusalMark + base) else { return false }
        return target.methods.allSatisfy { wanted in
            guard let function = functions[base + "." + wanted.name] else { return false }
            return function.parameterCount == wanted.parameterCount + 1
                && function.returnCount == wanted.resultCount
        }
    }
}
