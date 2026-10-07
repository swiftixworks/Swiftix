/// `printf`-style formatting for the text built-ins: backslash-escape expansion
/// (shared by `echo -e`, `printf`, `paste -d`) and the `%` conversion engine
/// behind `printf`. Pure functions over strings and bytes — no I/O, no state —
/// so they run anywhere on the loop-bound executor and are trivially testable.
extension BuiltinCommands {

    /// Expand backslash escapes: `\a \b \e \f \n \r \t \v \\`, octal `\0NNN`
    /// (and `\NNN` unless `octalNeedsZero`; `zeroPrefixedOctal` lets a leading
    /// zero be followed by three more digits), hex `\xHH`, and `\c` (stop: discard
    /// the rest of the output). Unknown escapes are kept verbatim. The result is
    /// bytes, because `\xHH` may produce something that is not UTF-8.
    static func expandEscapes(_ text: String, octalNeedsZero: Bool,
                              zeroPrefixedOctal: Bool = false) -> (bytes: [UInt8], stopped: Bool) {
        var out: [UInt8] = []
        let bytes = Array(text.utf8)
        var index = 0
        func isOctal(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x37 }
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x41 + 10
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < bytes.count else {
                out.append(byte)
                index += 1
                continue
            }
            let next = bytes[index + 1]
            index += 2
            switch next {
            case UInt8(ascii: "a"): out.append(0x07)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "e"), UInt8(ascii: "E"): out.append(0x1B)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "v"): out.append(0x0B)
            case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "c"): return (out, true)
            case UInt8(ascii: "x"):
                var value: UInt8 = 0
                var digits = 0
                while digits < 2, index < bytes.count, let digit = hexValue(bytes[index]) {
                    value = value << 4 | digit
                    index += 1
                    digits += 1
                }
                if digits == 0 { out += [UInt8(ascii: "\\"), next] } else { out.append(value) }
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                if octalNeedsZero, next != UInt8(ascii: "0") {
                    out += [UInt8(ascii: "\\"), next]
                    break
                }
                // `\0NNN` (echo, %b) takes three digits after the zero; a plain
                // `\NNN` (printf formats) takes three digits in all.
                let afterZero = octalNeedsZero || (zeroPrefixedOctal && next == UInt8(ascii: "0"))
                var value = afterZero ? 0 : Int(next - 0x30)
                var digits = afterZero ? 0 : 1
                while digits < 3, index < bytes.count, isOctal(bytes[index]) {
                    value = value * 8 + Int(bytes[index] - 0x30)
                    index += 1
                    digits += 1
                }
                out.append(UInt8(truncatingIfNeeded: value))
            default:
                out += [UInt8(ascii: "\\"), next]
            }
        }
        return (out, false)
    }

    /// Format `args` according to a `printf(1)` format string. Supports the
    /// conversions `%d %i %u %o %x %X %c %s %b %e %E %f %F %g %G %%` with the
    /// flags `- 0 + space #`, a width, and a precision (each may be `*`). The
    /// format is reused while arguments remain; missing arguments are the empty
    /// string / zero. Returns the output bytes and any diagnostics (an invalid
    /// number still formats as far as it parsed, as coreutils does).
    static func formatPrintf(_ format: String, _ args: [String]) -> (bytes: [UInt8], errors: [String]) {
        var out: [UInt8] = []
        var errors: [String] = []
        var argIndex = 0
        var stopped = false
        let chars = Array(format)

        func nextArg() -> String? {
            defer { argIndex += 1 }
            return argIndex < args.count ? args[argIndex] : nil
        }
        func integer(_ text: String?) -> Int {
            guard let text, !text.isEmpty else { return 0 }
            // `'c` / `"c` is the character's code point.
            if let quote = text.first, quote == "'" || quote == "\"" {
                return text.dropFirst().unicodeScalars.first.map { Int($0.value) } ?? 0
            }
            var body = Substring(text)
            var negative = false
            if let sign = body.first, sign == "-" || sign == "+" { negative = sign == "-"; body = body.dropFirst() }
            let value: Int?
            if body.hasPrefix("0x") || body.hasPrefix("0X") { value = Int(body.dropFirst(2), radix: 16) }
            else if body.hasPrefix("0"), body.count > 1 { value = Int(body.dropFirst(), radix: 8) }
            else { value = Int(body) }
            if let value { return negative ? -value : value }
            // Fall back to the leading digits, reporting the problem.
            let digits = body.prefix { $0.isNumber }
            errors.append(digits.isEmpty ? "'\(text)': expected a numeric value"
                                         : "'\(text)': value not completely converted")
            let partial = Int(digits) ?? 0
            return negative ? -partial : partial
        }
        func floating(_ text: String?) -> Double {
            guard let text, !text.isEmpty else { return 0 }
            if let value = Double(text) { return value }
            if text.hasPrefix("0x") || text.hasPrefix("0X") || text.hasPrefix("'") || text.hasPrefix("\"") {
                return Double(integer(text))
            }
            errors.append("'\(text)': expected a numeric value")
            return 0
        }
        func pad(_ body: String, width: Int, left: Bool, zero: Bool) -> String {
            guard body.count < width else { return body }
            let fill = width - body.count
            if left { return body + String(repeating: " ", count: fill) }
            guard zero else { return String(repeating: " ", count: fill) + body }
            // Zeros go after the sign / radix prefix.
            var prefix = ""
            var digits = Substring(body)
            if let sign = digits.first, sign == "-" || sign == "+" || sign == " " { prefix.append(sign); digits = digits.dropFirst() }
            if digits.hasPrefix("0x") || digits.hasPrefix("0X") { prefix += digits.prefix(2); digits = digits.dropFirst(2) }
            return prefix + String(repeating: "0", count: fill) + digits
        }

        /// One pass over the format; returns whether any argument was consumed.
        func pass() {
            var i = 0
            while i < chars.count, !stopped {
                let c = chars[i]
                if c == "\\" {
                    // Take the whole escape (up to `\0NNN` / `\xHH`) and expand it.
                    var end = i + 2
                    if i + 1 < chars.count {
                        let kind = chars[i + 1]
                        if kind == "x" { while end < chars.count, end < i + 4, chars[end].isHexDigit { end += 1 } }
                        else if ("0"..."7").contains(kind) { while end < chars.count, end < i + 4, ("0"..."7").contains(chars[end]) { end += 1 } }
                    }
                    let expanded = expandEscapes(String(chars[i..<min(end, chars.count)]), octalNeedsZero: false)
                    out += expanded.bytes
                    if expanded.stopped { stopped = true }
                    i = min(end, chars.count)
                    continue
                }
                guard c == "%" else {
                    out += Array(String(c).utf8)
                    i += 1
                    continue
                }
                i += 1
                guard i < chars.count else { out.append(UInt8(ascii: "%")); break }
                if chars[i] == "%" { out.append(UInt8(ascii: "%")); i += 1; continue }
                var left = false, zero = false, plus = false, space = false, alternate = false
                while i < chars.count, "-0+ #".contains(chars[i]) {
                    switch chars[i] {
                    case "-": left = true
                    case "0": zero = true
                    case "+": plus = true
                    case " ": space = true
                    default: alternate = true
                    }
                    i += 1
                }
                var width = 0
                if i < chars.count, chars[i] == "*" {
                    width = integer(nextArg())
                    if width < 0 { left = true; width = -width }
                    i += 1
                } else {
                    while i < chars.count, let digit = chars[i].wholeNumberValue, chars[i].isASCII { width = width * 10 + digit; i += 1 }
                }
                var precision: Int? = nil
                if i < chars.count, chars[i] == "." {
                    i += 1
                    var value = 0
                    if i < chars.count, chars[i] == "*" {
                        value = integer(nextArg())
                        i += 1
                    } else {
                        while i < chars.count, let digit = chars[i].wholeNumberValue, chars[i].isASCII { value = value * 10 + digit; i += 1 }
                    }
                    precision = value < 0 ? nil : value
                }
                // Length modifiers are accepted and ignored.
                while i < chars.count, "hlLqjzt".contains(chars[i]) { i += 1 }
                guard i < chars.count else {
                    errors.append("%\(String(chars[(chars.lastIndex(of: "%") ?? 0)...].dropFirst())): invalid conversion specification")
                    break
                }
                let conversion = chars[i]
                i += 1
                var body: String
                switch conversion {
                case "d", "i":
                    let value = integer(nextArg())
                    var digits = String(value.magnitude)
                    if let precision { digits = String(repeating: "0", count: max(0, precision - digits.count)) + digits }
                    body = (value < 0 ? "-" : (plus ? "+" : (space ? " " : ""))) + digits
                    out += Array(pad(body, width: width, left: left, zero: zero && precision == nil).utf8)
                case "u", "o", "x", "X":
                    let value = integer(nextArg())
                    let magnitude = UInt(bitPattern: value)
                    let radix = conversion == "o" ? 8 : (conversion == "u" ? 10 : 16)
                    var digits = String(magnitude, radix: radix, uppercase: conversion == "X")
                    if let precision { digits = String(repeating: "0", count: max(0, precision - digits.count)) + digits }
                    if alternate, magnitude != 0 {
                        if conversion == "o" { digits = "0" + digits }
                        if conversion == "x" { digits = "0x" + digits }
                        if conversion == "X" { digits = "0X" + digits }
                    }
                    out += Array(pad(digits, width: width, left: left, zero: zero && precision == nil).utf8)
                case "c":
                    body = String((nextArg() ?? "").prefix(1))
                    out += Array(pad(body, width: width, left: left, zero: false).utf8)
                case "s":
                    body = nextArg() ?? ""
                    if let precision { body = String(body.prefix(precision)) }
                    out += Array(pad(body, width: width, left: left, zero: false).utf8)
                case "b":
                    let expanded = expandEscapes(nextArg() ?? "", octalNeedsZero: false, zeroPrefixedOctal: true)
                    var bytes = expanded.bytes
                    if let precision { bytes = Array(bytes.prefix(precision)) }
                    let fill = [UInt8](repeating: 0x20, count: max(0, width - bytes.count))
                    out += left ? bytes + fill : fill + bytes
                    if expanded.stopped { stopped = true }
                case "e", "E", "f", "F", "g", "G":
                    let value = floating(nextArg())
                    body = formatFloat(value, conversion: conversion, precision: precision, alternate: alternate)
                    if value.sign == .plus, !value.isNaN { body = (plus ? "+" : (space ? " " : "")) + body }
                    out += Array(pad(body, width: width, left: left, zero: zero && value.isFinite).utf8)
                default:
                    errors.append("%\(conversion): invalid conversion specification")
                    stopped = true
                }
            }
        }

        repeat {
            let before = argIndex
            pass()
            // A format that consumes nothing would loop forever.
            if argIndex == before { break }
        } while argIndex < args.count && !stopped
        return (out, errors)
    }

    /// Format a floating-point value like C's `%e`, `%f`, or `%g` (uppercase
    /// variants included), without Foundation. Digits come from exact decimal
    /// long arithmetic on the binary value, so rounding is correct (half-to-even
    /// on the true value) at any precision.
    static func formatFloat(_ value: Double, conversion: Character, precision: Int?, alternate: Bool = false) -> String {
        let upper = conversion.isUppercase
        if value.isNaN { return upper ? "NAN" : "nan" }
        let sign = value.sign == .minus ? "-" : ""
        if value.isInfinite { return sign + (upper ? "INF" : "inf") }
        let magnitude = value.magnitude
        let places = precision ?? 6

        switch conversion {
        case "f", "F":
            return sign + fixedDigits(magnitude, places: places, alternate: alternate)
        case "e", "E":
            return sign + exponentDigits(magnitude, places: places, upper: upper, alternate: alternate)
        default:
            // %g: P significant digits; scientific when the exponent is < -4 or >= P.
            let significant = places == 0 ? 1 : places
            let (digits, exponent) = decimalDigits(magnitude, significant: significant)
            var body: String
            if exponent < -4 || exponent >= significant {
                var mantissa = String(digits.prefix(1))
                let fraction = String(digits.dropFirst())
                if !fraction.isEmpty { mantissa += "." + fraction }
                if !alternate { mantissa = trimTrailingZeros(mantissa) }
                let exp = abs(exponent)
                body = mantissa + (upper ? "E" : "e") + (exponent < 0 ? "-" : "+") + (exp < 10 ? "0\(exp)" : "\(exp)")
            } else {
                body = fixedDigits(magnitude, places: max(0, significant - 1 - exponent), alternate: alternate)
                if !alternate { body = trimTrailingZeros(body) }
            }
            return sign + body
        }
    }

    private static func trimTrailingZeros(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var trimmed = Substring(text)
        while trimmed.hasSuffix("0") { trimmed = trimmed.dropLast() }
        if trimmed.hasSuffix(".") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    /// The exact decimal expansion of a finite non-negative double, as an
    /// integer-part digit array and a fraction digit array (most significant
    /// first). Every double is m·2^e, so the expansion is finite.
    private static func exactDecimal(_ value: Double) -> (integer: [UInt8], fraction: [UInt8]) {
        guard value != 0 else { return ([0], []) }
        var mantissa = value.significandBitPattern
        var exponent = Int(value.exponentBitPattern)
        if exponent == 0 { exponent = 1 } else { mantissa |= 1 << 52 }
        exponent -= 1075                      // value = mantissa * 2^exponent
        // Decimal digits of the mantissa, least significant first.
        var digits: [UInt8] = []
        var rest = mantissa
        while rest > 0 { digits.append(UInt8(rest % 10)); rest /= 10 }
        if exponent >= 0 {
            for _ in 0..<exponent {
                var carry: UInt8 = 0
                for index in digits.indices {
                    let doubled = digits[index] * 2 + carry
                    digits[index] = doubled % 10
                    carry = doubled / 10
                }
                if carry > 0 { digits.append(carry) }
            }
            return (digits.reversed(), [])
        }
        // Divide by 2 `-exponent` times: each halving appends one fraction digit.
        var whole = Array(digits.reversed())          // most significant first
        var fraction: [UInt8] = []
        for _ in 0..<(-exponent) {
            var remainder: UInt8 = 0
            for index in whole.indices {
                let current = remainder * 10 + whole[index]
                whole[index] = current / 2
                remainder = current % 2
            }
            for index in fraction.indices {
                let current = remainder * 10 + fraction[index]
                fraction[index] = current / 2
                remainder = current % 2
            }
            if remainder > 0 { fraction.append(5) }
        }
        while whole.count > 1, whole[0] == 0 { whole.removeFirst() }
        return (whole, fraction)
    }

    /// Round a digit string (integer digits followed by fraction digits) to keep
    /// `keep` digits, half-to-even on the exact value. Returns the kept digits
    /// (one longer when the round carried out of the top).
    private static func roundDigits(_ digits: [UInt8], keep: Int) -> (digits: [UInt8], carried: Bool) {
        guard keep < digits.count else {
            return (digits + [UInt8](repeating: 0, count: keep - digits.count), false)
        }
        var kept = Array(digits[..<keep])
        let next = digits[keep]
        let tailNonZero = digits[(keep + 1)...].contains { $0 != 0 }
        let roundUp = next > 5 || (next == 5 && (tailNonZero || (kept.last ?? 0) % 2 == 1))
        guard roundUp else { return (kept, false) }
        var index = kept.count - 1
        while index >= 0 {
            if kept[index] == 9 { kept[index] = 0; index -= 1 } else { kept[index] += 1; return (kept, false) }
        }
        return ([1] + kept, true)
    }

    private static func fixedDigits(_ value: Double, places: Int, alternate: Bool) -> String {
        let (integer, fraction) = exactDecimal(value)
        let rounded = roundDigits(integer + fraction, keep: integer.count + places).digits
        let split = rounded.count - places
        let whole = String(decoding: rounded[..<split].map { $0 + 0x30 }, as: UTF8.self)
        let part = String(decoding: rounded[split...].map { $0 + 0x30 }, as: UTF8.self)
        return places == 0 ? whole + (alternate ? "." : "") : whole + "." + part
    }

    /// The first `significant` digits of `value` (rounded) and its decimal
    /// exponent, i.e. value ≈ d.ddd × 10^exponent.
    private static func decimalDigits(_ value: Double, significant: Int) -> (digits: String, exponent: Int) {
        guard value != 0 else { return (String(repeating: "0", count: significant), 0) }
        let (integer, fraction) = exactDecimal(value)
        var all = integer + fraction
        var exponent = integer.count - 1
        // Strip leading zeros (values below 1).
        var leading = 0
        while leading < all.count - 1, all[leading] == 0 { leading += 1 }
        all.removeFirst(leading)
        exponent -= leading
        let rounded = roundDigits(all, keep: significant)
        var digits = rounded.digits
        if rounded.carried { exponent += 1; digits.removeLast() }
        return (String(decoding: digits.map { $0 + 0x30 }, as: UTF8.self), exponent)
    }

    private static func exponentDigits(_ value: Double, places: Int, upper: Bool, alternate: Bool) -> String {
        let (digits, exponent) = decimalDigits(value, significant: places + 1)
        var body = String(digits.prefix(1))
        if places > 0 { body += "." + digits.dropFirst() } else if alternate { body += "." }
        let exp = abs(exponent)
        return body + (upper ? "E" : "e") + (exponent < 0 ? "-" : "+") + (exp < 10 ? "0\(exp)" : "\(exp)")
    }
}
