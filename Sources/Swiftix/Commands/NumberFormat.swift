/// printf-style number formatting and strtod-style number parsing for the
/// built-in commands, written against the standard library only (the core may
/// not import Foundation, so there is no `String(format:)`).
///
/// `%f` / `%e` / `%g` are produced from the *exact* decimal expansion of the
/// binary value (a small base-10^9 big integer), then rounded half-to-even at
/// the requested digit — the same result a correctly rounding C library gives,
/// for every finite `Double`. Integer conversions (`%d %i %u %o %x %X`) and the
/// shared sign / width / zero-padding rules live here too so that `awk`,
/// `printf`, `seq`, `bc`, … format numbers the same way.
///
/// Concurrency: a caseless enum of pure functions over value types. It holds
/// no state, so it is safe from any context; in practice it is only called by
/// command bodies on the kernel's single serial executor.
enum NumberFormat {

    /// The printf flag characters.
    struct Flags: OptionSet {
        let rawValue: UInt8
        /// `-`: pad on the right instead of the left.
        static let leftAlign = Flags(rawValue: 1 << 0)
        /// `0`: pad with zeros after the sign instead of spaces before it.
        static let zeroPad = Flags(rawValue: 1 << 1)
        /// `+`: always print a sign.
        static let plus = Flags(rawValue: 1 << 2)
        /// ` `: print a space where a `+` would go.
        static let space = Flags(rawValue: 1 << 3)
        /// `#`: alternate form (keep the decimal point / trailing zeros, `0x`).
        static let alternate = Flags(rawValue: 1 << 4)
    }

    // MARK: - Floating point

    /// Format `value` with a floating conversion: `f F e E g G`. `precision`
    /// defaults to 6 as in C. Infinities and NaN print as `inf` / `nan`
    /// (upper-cased for the capital conversions) and are never zero-padded.
    static func format(_ value: Double,
                       conversion: Character,
                       flags: Flags = [],
                       width: Int = 0,
                       precision: Int? = nil) -> String {
        let upper = conversion == "E" || conversion == "F" || conversion == "G"
        let negative = value.sign == .minus && !value.isNaN
        let sign = negative ? "-" : flags.contains(.plus) ? "+" : flags.contains(.space) ? " " : ""
        if value.isNaN || value.isInfinite {
            let word = value.isNaN ? "nan" : "inf"
            return pad(sign: sign, body: upper ? word.uppercased() : word,
                       flags: flags.subtracting(.zeroPad), width: width)
        }
        let decimal = ExactDecimal(value.magnitude)
        let digits = Swift.max(0, precision ?? 6)
        let alternate = flags.contains(.alternate)
        let body: String
        switch conversion {
        case "f", "F":
            body = fixed(decimal, digits, alternate)
        case "e", "E":
            body = exponential(decimal, digits, alternate, upper: upper)
        default:
            body = general(decimal, digits, alternate, upper: upper)
        }
        return pad(sign: sign, body: body, flags: flags, width: width)
    }

    /// The exact decimal expansion of a non-negative finite double:
    /// `0.d1 d2 d3 … × 10^point` (so `point` digits sit before the decimal
    /// point). `digits` has no leading zero and is empty for zero.
    private struct ExactDecimal {
        var digits: [UInt8] = []
        var point = 0

        init(digits: [UInt8], point: Int) {
            self.digits = digits
            self.point = point
        }

        init(_ magnitude: Double) {
            let bits = magnitude.bitPattern
            let rawExponent = Int((bits >> 52) & 0x7FF)
            var mantissa = bits & ((1 << 52) - 1)
            var exponent: Int
            if rawExponent == 0 {
                exponent = -1074
            } else {
                mantissa |= 1 << 52
                exponent = rawExponent - 1075
            }
            guard mantissa != 0 else { return }
            while mantissa & 1 == 0, exponent < 0 {
                mantissa >>= 1
                exponent += 1
            }
            // value = mantissa × 2^exponent. For a negative exponent that is
            // mantissa × 5^k / 10^k, so every case is one big integer plus a
            // decimal-point shift.
            let base: UInt64 = 1_000_000_000
            var limbs: [UInt32] = []
            var rest = mantissa
            while rest > 0 {
                limbs.append(UInt32(rest % base))
                rest /= base
            }
            func multiply(_ limbs: inout [UInt32], by factor: UInt64) {
                var carry: UInt64 = 0
                for index in limbs.indices {
                    let product = UInt64(limbs[index]) * factor + carry
                    limbs[index] = UInt32(product % base)
                    carry = product / base
                }
                while carry > 0 {
                    limbs.append(UInt32(carry % base))
                    carry /= base
                }
            }
            var fractionDigits = 0
            if exponent >= 0 {
                var remaining = exponent
                while remaining >= 29 {
                    multiply(&limbs, by: 1 << 29)
                    remaining -= 29
                }
                if remaining > 0 { multiply(&limbs, by: 1 << UInt64(remaining)) }
            } else {
                var remaining = -exponent
                fractionDigits = remaining
                while remaining >= 13 {
                    multiply(&limbs, by: 1_220_703_125)   // 5^13
                    remaining -= 13
                }
                if remaining > 0 {
                    var factor: UInt64 = 1
                    for _ in 0..<remaining { factor *= 5 }
                    multiply(&limbs, by: factor)
                }
            }
            var out: [UInt8] = []
            out.reserveCapacity(limbs.count * 9)
            for (offset, limb) in limbs.reversed().enumerated() {
                var chunk: [UInt8] = []
                var value = limb
                for _ in 0..<9 {
                    chunk.append(UInt8(value % 10))
                    value /= 10
                }
                chunk.reverse()
                if offset == 0, let firstNonZero = chunk.firstIndex(where: { $0 != 0 }) {
                    out.append(contentsOf: chunk[firstNonZero...])
                } else {
                    out.append(contentsOf: chunk)
                }
            }
            digits = out
            point = out.count - fractionDigits
        }

        /// Keep the first `keep` digits, rounding half-to-even on the exact
        /// remainder. A carry out of the top digit grows `point` by one.
        func rounded(keeping keep: Int) -> ExactDecimal {
            if keep >= digits.count { return self }
            if keep < 0 { return ExactDecimal(digits: [], point: 0) }
            let next = digits[keep]
            let restNonZero = digits[(keep + 1)...].contains { $0 != 0 }
            let previousOdd = keep > 0 && digits[keep - 1] % 2 == 1
            let roundUp = next > 5 || (next == 5 && (restNonZero || previousOdd))
            var kept = Array(digits[..<keep])
            var newPoint = point
            if roundUp {
                var index = keep - 1
                while index >= 0 {
                    if kept[index] == 9 {
                        kept[index] = 0
                        index -= 1
                    } else {
                        kept[index] += 1
                        break
                    }
                }
                if index < 0 {
                    // 9.99… rolled over: still `keep` digits, one place higher.
                    kept.insert(1, at: 0)
                    if kept.count > 1 { kept.removeLast() }
                    newPoint += 1
                }
            }
            if kept.isEmpty { return ExactDecimal(digits: [], point: 0) }
            return ExactDecimal(digits: kept, point: newPoint)
        }
    }

    private static func text(_ digits: ArraySlice<UInt8>) -> String {
        String(decoding: digits.map { $0 + 0x30 }, as: UTF8.self)
    }

    private static func zeros(_ count: Int) -> String {
        String(repeating: "0", count: Swift.max(0, count))
    }

    /// `%f` body (no sign): `ddd.ddd` with exactly `precision` fraction digits.
    private static func fixed(_ decimal: ExactDecimal, _ precision: Int, _ alternate: Bool) -> String {
        let value = decimal.rounded(keeping: decimal.point + precision)
        var whole = "0"
        var fraction = ""
        if !value.digits.isEmpty {
            let count = value.digits.count
            if value.point > 0 {
                whole = text(value.digits[..<Swift.min(value.point, count)]) + zeros(value.point - count)
            }
            if value.point < 0 { fraction = zeros(-value.point) }
            if value.point < count { fraction += text(value.digits[Swift.max(value.point, 0)...]) }
        }
        fraction += zeros(precision - fraction.count)
        if precision == 0 { return alternate ? whole + "." : whole }
        return whole + "." + fraction
    }

    /// `%e` body (no sign): `d.ddde±XX`.
    private static func exponential(_ decimal: ExactDecimal, _ precision: Int, _ alternate: Bool,
                                    upper: Bool) -> String {
        var mantissa = zeros(precision + 1)
        var exponent = 0
        if !decimal.digits.isEmpty {
            let value = decimal.rounded(keeping: precision + 1)
            mantissa = text(value.digits[...]) + zeros(precision + 1 - value.digits.count)
            exponent = value.point - 1
        }
        var out = String(mantissa.prefix(1))
        if precision > 0 || alternate { out += "." }
        out += mantissa.dropFirst()
        out += upper ? "E" : "e"
        out += exponent < 0 ? "-" : "+"
        let magnitude = String(exponent.magnitude)
        out += magnitude.count < 2 ? "0" + magnitude : magnitude
        return out
    }

    /// `%g` body (no sign): the shorter of `%e` / `%f` at `precision`
    /// significant digits, with trailing zeros removed unless `alternate`.
    private static func general(_ decimal: ExactDecimal, _ precision: Int, _ alternate: Bool,
                                upper: Bool) -> String {
        let significant = precision == 0 ? 1 : precision
        var exponent = 0
        if !decimal.digits.isEmpty {
            exponent = decimal.rounded(keeping: significant).point - 1
        }
        if exponent >= -4 && exponent < significant {
            let body = fixed(decimal, significant - 1 - exponent, alternate)
            return alternate ? body : trimFraction(body)
        }
        let body = exponential(decimal, significant - 1, alternate, upper: upper)
        if alternate { return body }
        guard let marker = body.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return body }
        return trimFraction(String(body[..<marker])) + body[marker...]
    }

    /// Drop trailing fraction zeros (and a then-bare decimal point).
    private static func trimFraction(_ body: String) -> String {
        guard body.contains(".") else { return body }
        var out = Substring(body)
        while out.hasSuffix("0") { out = out.dropLast() }
        if out.hasSuffix(".") { out = out.dropLast() }
        return String(out)
    }

    // MARK: - Integers

    /// Format `value` with an integer conversion: `d i` (signed), `u`
    /// (unsigned), `o`, `x`, `X` (the two's-complement bit pattern, as C prints
    /// a negative `long` with those conversions). A `precision` is the minimum
    /// number of digits and, as in C, disables the `0` flag.
    static func formatInteger(_ value: Int64,
                              conversion: Character,
                              flags: Flags = [],
                              width: Int = 0,
                              precision: Int? = nil) -> String {
        var sign = ""
        var digits: String
        let pattern = UInt64(bitPattern: value)
        switch conversion {
        case "u":
            digits = String(pattern)
        case "o":
            digits = String(pattern, radix: 8)
        case "x":
            digits = String(pattern, radix: 16)
        case "X":
            digits = String(pattern, radix: 16, uppercase: true)
        default:
            digits = String(value.magnitude)
            sign = value < 0 ? "-" : flags.contains(.plus) ? "+" : flags.contains(.space) ? " " : ""
        }
        var effective = flags
        if let precision {
            if precision == 0, value == 0 { digits = "" }
            digits = zeros(precision - digits.count) + digits
            effective.remove(.zeroPad)
        }
        if flags.contains(.alternate) {
            if conversion == "o", !digits.hasPrefix("0") { digits = "0" + digits }
            if conversion == "x", value != 0 { sign += "0x" }
            if conversion == "X", value != 0 { sign += "0X" }
        }
        return pad(sign: sign, body: digits, flags: effective, width: width)
    }

    // MARK: - Padding

    /// Apply a field width to `sign + body`: spaces on the left by default,
    /// spaces on the right for `-`, zeros between sign and body for `0`.
    static func pad(sign: String = "", body: String, flags: Flags = [], width: Int = 0) -> String {
        let length = sign.count + body.count
        guard length < width else { return sign + body }
        let fill = width - length
        if flags.contains(.leftAlign) {
            return sign + body + String(repeating: " ", count: fill)
        }
        if flags.contains(.zeroPad) {
            return sign + String(repeating: "0", count: fill) + body
        }
        return String(repeating: " ", count: fill) + sign + body
    }

    // MARK: - Parsing

    /// Parse the longest decimal floating-point prefix of `text`, `strtod`
    /// style: optional leading white space, an optional sign, digits with an
    /// optional fraction, and an optional exponent (taken only when it has
    /// digits). Returns the value and the number of characters consumed
    /// (leading white space included), or `nil` when no number starts there.
    /// Hexadecimal, `inf` and `nan` spellings are deliberately not numbers.
    static func parseDouble(_ text: Substring) -> (value: Double, length: Int)? {
        let bytes = text.utf8
        var index = bytes.startIndex
        let end = bytes.endIndex
        var consumed = 0
        func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
        while index < end {
            let byte = bytes[index]
            guard byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) else { break }
            bytes.formIndex(after: &index)
            consumed += 1
        }
        let numberStart = index
        if index < end, bytes[index] == 0x2B || bytes[index] == 0x2D {
            bytes.formIndex(after: &index)
        }
        var digitCount = 0
        while index < end, isDigit(bytes[index]) {
            bytes.formIndex(after: &index)
            digitCount += 1
        }
        if index < end, bytes[index] == 0x2E {
            var probe = bytes.index(after: index)
            var fractionDigits = 0
            while probe < end, isDigit(bytes[probe]) {
                bytes.formIndex(after: &probe)
                fractionDigits += 1
            }
            if digitCount + fractionDigits > 0 {
                index = probe
                digitCount += fractionDigits
            }
        }
        guard digitCount > 0 else { return nil }
        if index < end, bytes[index] == 0x65 || bytes[index] == 0x45 {
            var probe = bytes.index(after: index)
            if probe < end, bytes[probe] == 0x2B || bytes[probe] == 0x2D {
                bytes.formIndex(after: &probe)
            }
            var exponentDigits = 0
            while probe < end, isDigit(bytes[probe]) {
                bytes.formIndex(after: &probe)
                exponentDigits += 1
            }
            if exponentDigits > 0 { index = probe }
        }
        let literal = String(Substring(bytes[numberStart..<index]))
        guard let value = Double(literal) else { return nil }
        return (value, consumed + bytes.distance(from: numberStart, to: index))
    }
}
