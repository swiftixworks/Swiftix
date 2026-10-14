/// The numbers of Go that are not `int`: what the VM does for them.
///
/// A VM value holds a number as one `Int64` and does not say which kind it
/// is. The compiler knows, and names the operation: after an operation
/// whose result can leave the range of a narrow type it calls the one that
/// brings it back (`$num.i8`), and for what 64-bit signed arithmetic gets
/// wrong it calls the one that gets it right (`$num.udiv` for a `uint64`).
/// The same family holds the functions of `strconv`, `unicode`,
/// `unicode/utf8`, and `strings` that take or give such a number.
///
/// Everything here is a pure function of its operands; what needs the heap
/// (a slice of runes) stays in the VM, and there is no process or executor
/// state.

/// A numeric type other than `int` and `uint8`, which the descriptor of a
/// type has always had.
enum GoNumberKind: UInt8, CaseIterable, Sendable {
    case int8 = 0x6A  // j
    case int16 = 0x6B  // k
    case int32 = 0x6C  // l
    case int64 = 0x6D  // m
    case uint = 0x75  // u
    case uint16 = 0x76  // v
    case uint32 = 0x77  // w
    case uint64 = 0x78  // x
    case uintptr = 0x70  // p
    case float32 = 0x66  // f
    case float64 = 0x64  // d

    /// Go's name for the type.
    var name: String {
        switch self {
        case .int8: return "int8"
        case .int16: return "int16"
        case .int32: return "int32"
        case .int64: return "int64"
        case .uint: return "uint"
        case .uint16: return "uint16"
        case .uint32: return "uint32"
        case .uint64: return "uint64"
        case .uintptr: return "uintptr"
        case .float32: return "float32"
        case .float64: return "float64"
        }
    }

    init?(name: Substring) {
        guard let kind = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = kind
    }

    var isFloat: Bool { self == .float32 || self == .float64 }

    var isUnsigned: Bool {
        switch self {
        case .uint, .uint16, .uint32, .uint64, .uintptr: return true
        default: return false
        }
    }

    /// An unsigned integer of 64 bits, held as its bit pattern.
    var isWideUnsigned: Bool { self == .uint || self == .uint64 || self == .uintptr }
}

enum GoNumeric {
    /// The reserved call names of the family, with the number of operands
    /// each one pops.
    static let argumentCounts: [String: Int] = [
        "$num.i8": 1, "$num.i16": 1, "$num.i32": 1, "$num.u16": 1, "$num.u32": 1,
        "$num.udiv": 2, "$num.urem": 2, "$num.ult": 2, "$num.ule": 2, "$num.ugt": 2,
        "$num.uge": 2, "$num.ushr": 2, "$num.ucount": 1,
        "$num.runes": 1, "$num.string": 1,
        "$strconv.ParseInt": 3, "$strconv.ParseUint": 3, "$strconv.FormatInt": 2,
        "$strconv.FormatUint": 2,
        "$unicode.IsDigit": 1, "$unicode.IsLetter": 1, "$unicode.IsSpace": 1,
        "$unicode.IsUpper": 1, "$unicode.IsLower": 1, "$unicode.ToUpper": 1,
        "$unicode.ToLower": 1,
        "$utf8.RuneCountInString": 1, "$utf8.ValidString": 1, "$utf8.RuneLen": 1,
        "$utf8.DecodeRuneInString": 1, "$utf8.EncodeRune": 2,
        "$strings.ContainsRune": 2, "$strings.IndexRune": 2, "$strings.IndexByte": 2,
        "$num.fadd": 2, "$num.fsub": 2, "$num.fmul": 2, "$num.fdiv": 2, "$num.fneg": 1,
        "$num.feq": 2, "$num.fne": 2, "$num.flt": 2, "$num.fle": 2, "$num.fgt": 2, "$num.fge": 2,
        "$num.f32": 1, "$num.itof": 1, "$num.utof": 1, "$num.ftoi": 1, "$num.ftoi32": 1,
        "$num.ftou": 1, "$num.fmin": 2, "$num.fmax": 2,
        "$math.Sqrt": 1, "$math.Floor": 1, "$math.Ceil": 1, "$math.Trunc": 1, "$math.Round": 1,
        "$math.RoundToEven": 1, "$math.Abs": 1, "$math.Max": 2, "$math.Min": 2, "$math.Pow": 2,
        "$math.Log": 1, "$math.Exp": 1,
        "$math.Mod": 2, "$math.Inf": 1, "$math.NaN": 0, "$math.IsNaN": 1, "$math.IsInf": 2,
        "$math.Signbit": 1, "$math.Copysign": 2, "$math.Float64bits": 1,
        "$math.Float64frombits": 1, "$math.Float32bits": 1, "$math.Float32frombits": 1,
        "$strconv.ParseFloat": 2, "$strconv.FormatFloat": 4, "$sort.Float64s": 1,
    ]

    /// The result of an operation on integers alone, or nil when `name` is
    /// not one. A division by zero panics as the instruction does.
    static func integer(_ name: String, _ operands: [Int64]) throws -> GoValue? {
        func unsigned(_ index: Int) -> UInt64 { UInt64(bitPattern: operands[index]) }
        if let float = floating(name, operands) { return float }
        switch name {
        case "$num.i8": return .int(Int64(Int8(truncatingIfNeeded: operands[0])))
        case "$num.i16": return .int(Int64(Int16(truncatingIfNeeded: operands[0])))
        case "$num.i32": return .int(Int64(Int32(truncatingIfNeeded: operands[0])))
        case "$num.u16": return .int(Int64(UInt16(truncatingIfNeeded: operands[0])))
        case "$num.u32": return .int(Int64(UInt32(truncatingIfNeeded: operands[0])))
        case "$num.udiv", "$num.urem":
            guard operands[1] != 0 else { throw GoRuntimePanic.divideByZero }
            let result = name == "$num.udiv" ? unsigned(0) / unsigned(1) : unsigned(0) % unsigned(1)
            return .int(Int64(bitPattern: result))
        case "$num.ult": return .bool(unsigned(0) < unsigned(1))
        case "$num.ule": return .bool(unsigned(0) <= unsigned(1))
        case "$num.ugt": return .bool(unsigned(0) > unsigned(1))
        case "$num.uge": return .bool(unsigned(0) >= unsigned(1))
        case "$num.ushr":
            // The count is that of the instruction: negative for a signed
            // count below zero, and any count of 64 or more shifts all out.
            guard operands[1] >= 0 else { throw GoRuntimePanic.negativeShift }
            return .int(operands[1] >= 64 ? 0 : Int64(bitPattern: unsigned(0) >> UInt64(operands[1])))
        case "$num.ucount":
            // An unsigned count that reads as negative is a large one.
            return .int(operands[0] < 0 || operands[0] > 64 ? 64 : operands[0])
        case "$unicode.ToUpper", "$unicode.ToLower":
            guard let narrowed = UInt32(exactly: operands[0]), let scalar = Unicode.Scalar(narrowed)
            else { return .int(operands[0]) }
            let mapped = name == "$unicode.ToUpper" ? GoUnicode.toUpper(scalar) : GoUnicode.toLower(scalar)
            return .int(Int64(mapped.value))
        case "$unicode.IsDigit": return .bool(GoUnicodeCategories.isDigit(operands[0]))
        case "$unicode.IsLetter": return .bool(GoUnicodeCategories.isLetter(operands[0]))
        case "$unicode.IsSpace": return .bool(GoUnicodeCategories.isSpace(operands[0]))
        case "$unicode.IsUpper": return .bool(GoUnicodeCategories.isUpper(operands[0]))
        case "$unicode.IsLower": return .bool(GoUnicodeCategories.isLower(operands[0]))
        case "$utf8.RuneLen": return .int(Int64(runeLength(operands[0])))
        default: return nil
        }
    }

    /// The result of an operation on floating-point numbers, each operand
    /// and result the bit pattern of a `float64`, or nil when `name` is not
    /// one. Nothing here panics: a division by zero is an infinity or a NaN.
    static func floating(_ name: String, _ operands: [Int64]) -> GoValue? {
        func number(_ index: Int) -> Double { Double(bitPattern: UInt64(bitPattern: operands[index])) }
        func bits(_ value: Double) -> GoValue { .int(Int64(bitPattern: value.bitPattern)) }
        switch name {
        case "$num.fadd": return bits(number(0) + number(1))
        case "$num.fsub": return bits(number(0) - number(1))
        case "$num.fmul": return bits(number(0) * number(1))
        case "$num.fdiv": return bits(number(0) / number(1))
        case "$num.fneg": return bits(-number(0))
        case "$num.feq": return .bool(number(0) == number(1))
        case "$num.fne": return .bool(number(0) != number(1))
        case "$num.flt": return .bool(number(0) < number(1))
        case "$num.fle": return .bool(number(0) <= number(1))
        case "$num.fgt": return .bool(number(0) > number(1))
        case "$num.fge": return .bool(number(0) >= number(1))
        // A `float32` is the `float64` with its value: rounding to the
        // narrower format after each operation is the operation of it.
        case "$num.f32": return bits(Double(Float(number(0))))
        case "$num.itof": return bits(Double(operands[0]))
        case "$num.utof": return bits(Double(UInt64(bitPattern: operands[0])))
        case "$num.ftoi": return .int(integer(number(0)))
        case "$num.ftoi32": return .int(Int64(narrow(number(0))))
        case "$num.ftou": return .int(Int64(bitPattern: unsigned(number(0))))
        case "$num.fmin", "$math.Min": return bits(minimum(number(0), number(1)))
        case "$num.fmax", "$math.Max": return bits(maximum(number(0), number(1)))
        case "$math.Sqrt": return bits(number(0).squareRoot())
        case "$math.Floor": return bits(number(0).rounded(.down))
        case "$math.Ceil": return bits(number(0).rounded(.up))
        case "$math.Trunc": return bits(number(0).rounded(.towardZero))
        case "$math.Round": return bits(number(0).rounded(.toNearestOrAwayFromZero))
        case "$math.RoundToEven": return bits(number(0).rounded(.toNearestOrEven))
        case "$math.Abs": return bits(number(0).magnitude)
        case "$math.Pow": return bits(GoFloat.pow(number(0), number(1)))
        case "$math.Log": return bits(GoFloat.log(number(0)))
        case "$math.Exp": return bits(GoFloat.exp(number(0)))
        case "$math.Mod": return bits(number(0).truncatingRemainder(dividingBy: number(1)))
        case "$math.Inf": return bits(operands[0] >= 0 ? .infinity : -.infinity)
        case "$math.NaN": return bits(GoFloat.goNaN)
        case "$math.IsNaN": return .bool(number(0).isNaN)
        case "$math.IsInf":
            let value = number(0)
            return .bool(
                value.isInfinite
                    && (operands[1] == 0 || (operands[1] > 0) == (value > 0)))
        case "$math.Signbit": return .bool(number(0).sign == .minus)
        case "$math.Copysign":
            return bits(Double(sign: number(1).sign, exponent: 0, significand: 1) * number(0).magnitude)
        case "$math.Float64bits", "$math.Float64frombits": return .int(operands[0])
        case "$math.Float32bits": return .int(Int64(Float(number(0)).bitPattern))
        case "$math.Float32frombits":
            return bits(Double(Float(bitPattern: UInt32(truncatingIfNeeded: operands[0]))))
        default: return nil
        }
    }

    // A conversion of a floating-point number to an integer keeps what is
    // before the point. For a number no integer of the type is, Go leaves
    // the result to the machine; these are the results of the reference
    // machine (arm64), which stops at the ends of the range and makes zero
    // of a NaN.

    /// To a signed integer of 64 bits.
    static func integer(_ value: Double) -> Int64 {
        if value.isNaN { return 0 }
        if value >= 9_223_372_036_854_775_808.0 { return .max }
        if value <= -9_223_372_036_854_775_808.0 { return .min }
        return Int64(value.rounded(.towardZero))
    }

    /// To a signed integer of 32 bits, from which the narrower types and
    /// the unsigned ones of 8 and 16 bits take their low bits.
    static func narrow(_ value: Double) -> Int32 {
        if value.isNaN { return 0 }
        if value >= 2_147_483_648.0 { return .max }
        if value <= -2_147_483_648.0 { return .min }
        return Int32(value.rounded(.towardZero))
    }

    /// To an unsigned integer of 64 bits.
    static func unsigned(_ value: Double) -> UInt64 {
        if value.isNaN || value <= 0 { return 0 }
        if value >= 18_446_744_073_709_551_616.0 { return .max }
        return UInt64(value.rounded(.towardZero))
    }

    /// Go's `math.Max`, which the builtin `max` shares: a NaN gives a NaN,
    /// and positive zero is the greater of the zeros.
    static func maximum(_ x: Double, _ y: Double) -> Double {
        if x == .infinity || y == .infinity { return .infinity }
        if x.isNaN || y.isNaN { return .nan }
        if x == 0, x == y { return x.sign == .minus ? y : x }
        return x > y ? x : y
    }

    /// Go's `math.Min`.
    static func minimum(_ x: Double, _ y: Double) -> Double {
        if x == -.infinity || y == -.infinity { return -.infinity }
        if x.isNaN || y.isNaN { return .nan }
        if x == 0, x == y { return x.sign == .minus ? x : y }
        return x < y ? x : y
    }

    /// What an unrecovered panic prints for a number of kind `kind`.
    static func panicValue(_ bits: Int64, _ kind: GoNumberKind) -> String? {
        if kind.isFloat { return panicText(Double(bitPattern: UInt64(bitPattern: bits))) }
        return GoFormat.number(bits, kind, GoFormat.Directive(verb: "v"))
    }

    /// What the run-time system prints for a floating-point number a
    /// program panicked with: `+1.500000e+000`. Go's `printfloat`.
    static func panicText(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.isInfinite { return number > 0 ? "+Inf" : "-Inf" }
        let digitCount = 7
        var value = number
        var sign: UInt8 = 0x2B
        var exponent = 0
        if value == 0 {
            if value.sign == .minus { sign = 0x2D }
        } else {
            if value < 0 {
                value = -value
                sign = 0x2D
            }
            while value >= 10 {
                exponent += 1
                value /= 10
            }
            while value < 1 {
                exponent -= 1
                value *= 10
            }
            var half = 5.0
            for _ in 0..<digitCount { half /= 10 }
            value += half
            if value >= 10 {
                exponent += 1
                value /= 10
            }
        }
        var digits: [UInt8] = []
        for _ in 0..<digitCount {
            let digit = Int(value)
            digits.append(UInt8(digit) + 0x30)
            value -= Double(digit)
            value *= 10
        }
        var text = [sign, digits[0], 0x2E] + digits[1...]
        text.append(0x65)
        text.append(exponent < 0 ? 0x2D : 0x2B)
        let magnitude = exponent.magnitude
        text.append(UInt8(magnitude / 100 % 10) + 0x30)
        text.append(UInt8(magnitude / 10 % 10) + 0x30)
        text.append(UInt8(magnitude % 10) + 0x30)
        return String(decoding: text, as: UTF8.self)
    }

    /// Bytes in the UTF-8 encoding of a code point, or -1 when it is none.
    static func runeLength(_ rune: Int64) -> Int {
        switch rune {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0xD800...0xDFFF: return -1
        case 0x800..<0x10000: return 3
        case 0x10000...0x10FFFF: return 4
        default: return -1
        }
    }

    /// The code point Go encodes for `rune`: itself, or U+FFFD for a value
    /// that is none.
    static func scalar(_ rune: Int64) -> Unicode.Scalar {
        UInt32(exactly: rune).flatMap(Unicode.Scalar.init) ?? "\u{FFFD}"
    }

    /// `strings.IndexRune`: the byte offset of the first `rune` in `text`,
    /// or -1. A value that is no code point is in no string of valid UTF-8.
    static func index(of rune: Int64, in text: String) -> Int {
        guard let narrowed = UInt32(exactly: rune), let wanted = Unicode.Scalar(narrowed) else {
            return -1
        }
        var offset = 0
        for scalar in text.unicodeScalars {
            if scalar == wanted { return offset }
            offset += UTF8.width(scalar)
        }
        return -1
    }

    // MARK: strconv

    /// How `strconv.ParseInt` and `ParseUint` fail.
    enum ParseFailure: Equatable {
        case syntax
        case range
        case base(Int64)
        case bitSize(Int64)

        init(_ failure: GoFloat.ParseFailure) {
            self = failure == .syntax ? .syntax : .range
        }

        /// The text of Go's `*strconv.NumError`.
        func message(function: String, text: String) -> String {
            let prefix = "strconv.\(function): parsing \(GoFormat.quote(text, asciiOnly: false)): "
            switch self {
            case .syntax: return prefix + "invalid syntax"
            case .range: return prefix + "value out of range"
            case .base(let base): return prefix + "invalid base \(base)"
            case .bitSize(let size): return prefix + "invalid bit size \(size)"
            }
        }
    }

    /// Go's `strconv.ParseUint`: the value, and how it failed if it did. A
    /// value out of range is the largest of the size, as Go returns it.
    static func parseUnsigned(
        _ text: String, base requested: Int64, bitSize requestedSize: Int64
    ) -> (value: UInt64, failure: ParseFailure?) {
        var digits = Array(text.utf8)[...]
        guard !digits.isEmpty else { return (0, .syntax) }
        var base = UInt64(0)
        var allowsUnderscores = false
        switch requested {
        case 2...36:
            base = UInt64(requested)
        case 0:
            // The prefix says: `0x`, `0o`, `0b`, a leading `0`, or decimal.
            base = 10
            if digits.first == 0x30 {
                let prefix = digits.dropFirst().first.map { $0 | 0x20 }
                if digits.count >= 3, prefix == 0x62 || prefix == 0x6F || prefix == 0x78 {
                    base = prefix == 0x62 ? 2 : (prefix == 0x6F ? 8 : 16)
                    digits = digits.dropFirst(2)
                } else {
                    base = 8
                    digits = digits.dropFirst()
                    if digits.isEmpty { return (0, nil) }
                }
            }
            allowsUnderscores = true
        default:
            return (0, .base(requested))
        }
        let bitSize: Int64 = requestedSize == 0 ? 64 : requestedSize
        guard (1...64).contains(bitSize) else { return (0, .bitSize(requestedSize)) }
        let maximum: UInt64 = bitSize == 64 ? .max : (UInt64(1) << UInt64(bitSize)) - 1
        var value = UInt64(0)
        var overflowed = false
        var sawUnderscore = false
        for byte in digits {
            var digit: UInt64
            switch byte {
            case 0x5F where allowsUnderscores:
                sawUnderscore = true
                continue
            case 0x30...0x39: digit = UInt64(byte - 0x30)
            case 0x61...0x7A: digit = UInt64(byte - 0x61) + 10
            case 0x41...0x5A: digit = UInt64(byte - 0x41) + 10
            default: return (0, .syntax)
            }
            guard digit < base else { return (0, .syntax) }
            if overflowed { continue }
            let (scaled, scaleOverflow) = value.multipliedReportingOverflow(by: base)
            let (sum, sumOverflow) = scaled.addingReportingOverflow(digit)
            if scaleOverflow || sumOverflow || sum > maximum {
                overflowed = true
                digit = 0
            } else {
                value = sum
            }
        }
        if sawUnderscore, !underscoresAreValid(Array(text.utf8)) { return (0, .syntax) }
        return overflowed ? (maximum, .range) : (value, nil)
    }

    /// Go's `underscoreOK`: underscores only after a base prefix, and each
    /// between two digits or after the prefix.
    static func underscoresAreValid(_ text: [UInt8]) -> Bool {
        var previous: UInt8 = 0x5E
        var index = 0
        if index < text.count, text[index] == 0x2B || text[index] == 0x2D { index += 1 }
        var hexadecimal = false
        if text.count - index >= 2, text[index] == 0x30 {
            let prefix = text[index + 1] | 0x20
            if prefix == 0x62 || prefix == 0x6F || prefix == 0x78 {
                index += 2
                previous = 0x30
                hexadecimal = prefix == 0x78
            }
        }
        while index < text.count {
            let byte = text[index]
            let isDigit =
                (0x30...0x39).contains(byte)
                || (hexadecimal && (0x61...0x66).contains(byte | 0x20))
            if isDigit {
                previous = 0x30
            } else if byte == 0x5F {
                guard previous == 0x30 else { return false }
                previous = 0x5F
            } else {
                guard previous != 0x5F else { return false }
                previous = 0x21
            }
            index += 1
        }
        return previous != 0x5F
    }

    /// Go's `strconv.ParseInt`.
    static func parseSigned(
        _ text: String, base: Int64, bitSize requestedSize: Int64
    ) -> (value: Int64, failure: ParseFailure?) {
        guard !text.isEmpty else { return (0, .syntax) }
        var magnitude = text[...]
        var negative = false
        if let sign = magnitude.utf8.first, sign == 0x2B || sign == 0x2D {
            negative = sign == 0x2D
            magnitude = magnitude.dropFirst()
        }
        let parsed = parseUnsigned(String(magnitude), base: base, bitSize: requestedSize)
        if let failure = parsed.failure, failure != .range { return (0, failure) }
        let bitSize: Int64 = requestedSize == 0 ? 64 : requestedSize
        let cutoff = UInt64(1) << UInt64(bitSize - 1)
        if !negative, parsed.value >= cutoff || parsed.failure == .range {
            return (Int64(bitPattern: cutoff - 1), .range)
        }
        if negative, parsed.value > cutoff || parsed.failure == .range {
            return (Int64(bitPattern: 0 &- cutoff), .range)
        }
        let value = Int64(bitPattern: parsed.value)
        return (negative ? 0 &- value : value, nil)
    }
}

extension GoFormat {
    /// An integer of a sized type under `directive`, or nil when the verb
    /// does not apply. The 64 bits are read as the kind says.
    static func number(_ bits: Int64, _ kind: GoNumberKind, _ directive: Directive) -> String? {
        if kind.isFloat {
            return GoFloat.formatted(
                Double(bitPattern: UInt64(bitPattern: bits)), bitSize: kind == .float32 ? 32 : 64,
                verb: directive.verb, plus: directive.plus, minus: directive.minus,
                sharp: directive.sharp, space: directive.space, zero: directive.zero,
                width: directive.width, precision: directive.precision,
                goSyntax: directive.goSyntax)
        }
        guard kind.isUnsigned else { return integer(bits, directive) }
        if bits >= 0 { return integer(bits, directive, unsigned: true) }
        return wide(UInt64(bitPattern: bits), directive)
    }
}

/// Go's `unicode.IsLetter`, `IsUpper`, `IsLower`, `IsDigit`, and `IsSpace`
/// over `GoUnicodeCategoryTables`, which pins them to the reference Go
/// release like the case mappings of `GoUnicode`.
enum GoUnicodeCategories {
    static func isLetter(_ rune: Int64) -> Bool { contains(rune, GoUnicodeCategoryTables.letter) }
    static func isUpper(_ rune: Int64) -> Bool { contains(rune, GoUnicodeCategoryTables.upper) }
    static func isLower(_ rune: Int64) -> Bool { contains(rune, GoUnicodeCategoryTables.lower) }
    static func isDigit(_ rune: Int64) -> Bool { contains(rune, GoUnicodeCategoryTables.digit) }
    static func isSpace(_ rune: Int64) -> Bool {
        contains(rune, GoUnicodeCategoryTables.whiteSpace)
    }

    /// Whether `rune` is in `table`, whose ranges are `first, last, stride`
    /// in ascending order: the last range that starts at or before it is
    /// the only one that can hold it.
    static func contains(_ rune: Int64, _ table: [UInt32]) -> Bool {
        guard let value = UInt32(exactly: rune) else { return false }
        var low = 0
        var high = table.count / 3
        while low < high {
            let middle = (low + high) / 2
            if table[middle * 3] <= value { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return false }
        let first = table[(low - 1) * 3]
        let last = table[(low - 1) * 3 + 1]
        let stride = table[(low - 1) * 3 + 2]
        return value <= last && (value - first) % stride == 0
    }
}

extension GoNumeric {
    /// Whether the keys of a map of this key type sort as unsigned 64-bit
    /// integers, which their bits alone do not show.
    static func ordersUnsigned(_ keyType: GoRuntimeType?) -> Bool {
        if case .number(let kind)? = keyType { return kind.isWideUnsigned || kind.isFloat }
        return false
    }

    /// The order of two such keys, as `GoFormat.keyOrder` gives it. Keys
    /// that are floating-point numbers sort by value, a NaN before any.
    static func unsignedOrder(
        _ lhs: GoValue, _ rhs: GoValue, _ keyType: GoRuntimeType?
    ) -> Int {
        guard case .int(let left) = lhs, case .int(let right) = rhs else {
            return GoFormat.keyOrder(lhs, rhs)
        }
        if case .number(let kind)? = keyType, kind.isFloat {
            let (a, b) = (
                Double(bitPattern: UInt64(bitPattern: left)),
                Double(bitPattern: UInt64(bitPattern: right))
            )
            if a.isNaN || b.isNaN { return a.isNaN == b.isNaN ? 0 : (a.isNaN ? -1 : 1) }
            return a < b ? -1 : (a > b ? 1 : 0)
        }
        let (a, b) = (UInt64(bitPattern: left), UInt64(bitPattern: right))
        return a < b ? -1 : (a > b ? 1 : 0)
    }
}
