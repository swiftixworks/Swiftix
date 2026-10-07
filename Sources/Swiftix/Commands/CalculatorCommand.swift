/// `bc` — the arbitrary-precision calculator language, as a built-in.
///
/// Four layers, top to bottom of this file:
///
/// - `BCNumber`: a decimal bignum (sign + little-endian decimal digits + scale)
///   with bc's scale rules for `+ - * / % ^` and `sqrt`, base-aware parsing and
///   printing (`ibase` / `obase`), and the `-l` math library (`s c a l e`).
/// - `BCLexer` / `BCParser`: the bc grammar with GNU's operator precedence
///   (relational below assignment, unary minus above `^`), statements,
///   `if`/`while`/`for`, `define`d functions with `auto` locals, and arrays.
/// - `BCInterpreter`: a tree-walking evaluator. Evaluation is `async` so loops
///   can flush output and yield to the event loop instead of spinning.
/// - The `bc` command: feeds files then standard input to the interpreter line
///   by line, executing each complete statement group as soon as it is read
///   (so it is usable interactively), reporting `(standard_in) N: syntax error`
///   and `Runtime error (func=…, adr=…): …` the way GNU bc does and carrying on.
///
/// Not implemented: array parameters / `auto` arrays, `read()`, the `j(n,x)`
/// Bessel function, and the interactive banner.
///
/// Concurrency: value types plus one interpreter object owned by the command
/// body, all on the single loop-bound executor. No shared state, no locks.

// MARK: - Decimal bignum

/// Unsigned magnitude helpers over little-endian decimal digit arrays with no
/// most-significant zeros (the empty array is zero).
private enum BCMagnitude {

    static func trimmed(_ digits: [UInt8]) -> [UInt8] {
        var end = digits.count
        while end > 0, digits[end - 1] == 0 { end -= 1 }
        return end == digits.count ? digits : Array(digits[..<end])
    }

    static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        var index = a.count - 1
        while index >= 0 {
            if a[index] != b[index] { return a[index] < b[index] ? -1 : 1 }
            index -= 1
        }
        return 0
    }

    static func add(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        let (long, short) = a.count >= b.count ? (a, b) : (b, a)
        var out = long
        var carry: UInt8 = 0
        for index in 0..<long.count {
            let sum = long[index] + (index < short.count ? short[index] : 0) + carry
            out[index] = sum >= 10 ? sum - 10 : sum
            carry = sum >= 10 ? 1 : 0
            if carry == 0, index >= short.count { break }
        }
        if carry != 0 {
            // The loop only leaves a carry after walking the whole array.
            out.append(1)
        }
        return out
    }

    /// `a - b`, requiring `a >= b`.
    static func subtract(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = a
        var borrow: Int = 0
        for index in 0..<a.count {
            var difference = Int(a[index]) - borrow - (index < b.count ? Int(b[index]) : 0)
            if difference < 0 {
                difference += 10
                borrow = 1
            } else {
                borrow = 0
            }
            out[index] = UInt8(difference)
            if borrow == 0, index >= b.count { break }
        }
        return trimmed(out)
    }

    static func multiply(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        if a.isEmpty || b.isEmpty { return [] }
        var accumulator = [Int](repeating: 0, count: a.count + b.count)
        for (i, x) in a.enumerated() where x != 0 {
            let factor = Int(x)
            for (j, y) in b.enumerated() {
                accumulator[i + j] += factor * Int(y)
            }
        }
        var out = [UInt8](repeating: 0, count: accumulator.count)
        var carry = 0
        for index in 0..<accumulator.count {
            let total = accumulator[index] + carry
            out[index] = UInt8(total % 10)
            carry = total / 10
        }
        return trimmed(out)
    }

    static func multiply(_ a: [UInt8], small factor: Int) -> [UInt8] {
        if a.isEmpty || factor == 0 { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(a.count + 10)
        var carry = 0
        for digit in a {
            let total = Int(digit) * factor + carry
            out.append(UInt8(total % 10))
            carry = total / 10
        }
        while carry > 0 {
            out.append(UInt8(carry % 10))
            carry /= 10
        }
        return out
    }

    static func add(_ a: [UInt8], small value: Int) -> [UInt8] {
        var out = a
        var carry = value
        var index = 0
        while carry > 0 {
            if index == out.count { out.append(0) }
            let total = Int(out[index]) + carry
            out[index] = UInt8(total % 10)
            carry = total / 10
            index += 1
        }
        return out
    }

    static func divide(_ a: [UInt8], small divisor: Int) -> (quotient: [UInt8], remainder: Int) {
        var out = [UInt8](repeating: 0, count: a.count)
        var remainder = 0
        var index = a.count - 1
        while index >= 0 {
            let current = remainder * 10 + Int(a[index])
            out[index] = UInt8(current / divisor)
            remainder = current % divisor
            index -= 1
        }
        return (trimmed(out), remainder)
    }

    /// Schoolbook long division; `b` must be non-zero.
    static func divide(_ a: [UInt8], _ b: [UInt8]) -> (quotient: [UInt8], remainder: [UInt8]) {
        if compare(a, b) < 0 { return ([], a) }
        if b.count <= 9 {
            var divisor = 0
            for digit in b.reversed() { divisor = divisor * 10 + Int(digit) }
            let (quotient, remainder) = divide(a, small: divisor)
            var digits: [UInt8] = []
            var rest = remainder
            while rest > 0 {
                digits.append(UInt8(rest % 10))
                rest /= 10
            }
            return (quotient, digits)
        }
        var quotient = [UInt8](repeating: 0, count: a.count)
        // The running remainder, little-endian; each step shifts the next
        // dividend digit in at the low end.
        var remainder: [UInt8] = []
        var index = a.count - 1
        while index >= 0 {
            if !(remainder.isEmpty && a[index] == 0) {
                remainder.insert(a[index], at: 0)
            }
            var digit: UInt8 = 0
            while compare(remainder, b) >= 0 {
                remainder = subtract(remainder, b)
                digit += 1
            }
            quotient[index] = digit
            index -= 1
        }
        return (trimmed(quotient), remainder)
    }

    /// Multiply by `10^count`.
    static func shiftedUp(_ a: [UInt8], by count: Int) -> [UInt8] {
        if a.isEmpty || count <= 0 { return a }
        return [UInt8](repeating: 0, count: count) + a
    }

    /// Divide by `10^count`, truncating.
    static func shiftedDown(_ a: [UInt8], by count: Int) -> [UInt8] {
        if count <= 0 { return a }
        if count >= a.count { return [] }
        return Array(a[count...])
    }

    /// Floor of the square root (Newton's iteration from above).
    static func squareRoot(_ value: [UInt8]) -> [UInt8] {
        if value.isEmpty { return [] }
        var estimate = shiftedUp([1], by: (value.count + 1) / 2)
        while true {
            let (quotient, _) = divide(value, estimate)
            let (next, _) = divide(add(estimate, quotient), small: 2)
            if compare(next, estimate) >= 0 { return estimate }
            estimate = next
        }
    }
}

/// A bc number: `(-1)^negative × digits × 10^-scale`.
struct BCNumber: Equatable {
    var negative = false
    /// Little-endian decimal digits of the unscaled integer; empty for zero.
    var digits: [UInt8] = []
    /// Number of digits after the decimal point.
    var scale = 0

    static let zero = BCNumber()
    static let one = BCNumber(1)

    init() {}

    init(_ value: Int) {
        negative = value < 0
        var rest = value.magnitude
        while rest > 0 {
            digits.append(UInt8(rest % 10))
            rest /= 10
        }
    }

    private init(negative: Bool, digits: [UInt8], scale: Int) {
        self.digits = BCMagnitude.trimmed(digits)
        self.negative = negative && !self.digits.isEmpty
        self.scale = scale
    }

    var isZero: Bool { digits.isEmpty }

    /// Number of digits before the decimal point (0 for a pure fraction).
    var integerDigitCount: Int { Swift.max(0, digits.count - scale) }

    /// The value truncated toward zero, when it fits an `Int`.
    var integerValue: Int? {
        let whole = BCMagnitude.shiftedDown(digits, by: scale)
        guard whole.count <= 18 else { return nil }
        var value = 0
        for digit in whole.reversed() { value = value * 10 + Int(digit) }
        return negative ? -value : value
    }

    /// The same value with exactly `newScale` fractional digits (truncating or
    /// zero-extending).
    func rescaled(to newScale: Int) -> BCNumber {
        if newScale == scale { return self }
        let shifted = newScale > scale
            ? BCMagnitude.shiftedUp(digits, by: newScale - scale)
            : BCMagnitude.shiftedDown(digits, by: scale - newScale)
        return BCNumber(negative: negative, digits: shifted, scale: newScale)
    }

    var negated: BCNumber { BCNumber(negative: !negative, digits: digits, scale: scale) }

    var integerPart: BCNumber { rescaled(to: 0) }

    static func compare(_ a: BCNumber, _ b: BCNumber) -> Int {
        if a.negative != b.negative { return a.negative ? -1 : 1 }
        let common = Swift.max(a.scale, b.scale)
        let result = BCMagnitude.compare(BCMagnitude.shiftedUp(a.digits, by: common - a.scale),
                                         BCMagnitude.shiftedUp(b.digits, by: common - b.scale))
        return a.negative ? -result : result
    }

    static func add(_ a: BCNumber, _ b: BCNumber) -> BCNumber {
        let common = Swift.max(a.scale, b.scale)
        let x = BCMagnitude.shiftedUp(a.digits, by: common - a.scale)
        let y = BCMagnitude.shiftedUp(b.digits, by: common - b.scale)
        if a.negative == b.negative {
            return BCNumber(negative: a.negative, digits: BCMagnitude.add(x, y), scale: common)
        }
        let order = BCMagnitude.compare(x, y)
        if order == 0 { return BCNumber(negative: false, digits: [], scale: common) }
        return order > 0
            ? BCNumber(negative: a.negative, digits: BCMagnitude.subtract(x, y), scale: common)
            : BCNumber(negative: b.negative, digits: BCMagnitude.subtract(y, x), scale: common)
    }

    static func subtract(_ a: BCNumber, _ b: BCNumber) -> BCNumber { add(a, b.negated) }

    /// bc multiplication: the result keeps
    /// `min(a.scale + b.scale, max(scale, a.scale, b.scale))` fractional digits.
    static func multiply(_ a: BCNumber, _ b: BCNumber, scale: Int) -> BCNumber {
        let full = a.scale + b.scale
        let kept = Swift.min(full, Swift.max(scale, a.scale, b.scale))
        let product = BCMagnitude.multiply(a.digits, b.digits)
        return BCNumber(negative: a.negative != b.negative,
                        digits: BCMagnitude.shiftedDown(product, by: full - kept), scale: kept)
    }

    /// Exact product (all `a.scale + b.scale` fractional digits).
    static func multiplyExact(_ a: BCNumber, _ b: BCNumber) -> BCNumber {
        multiply(a, b, scale: a.scale + b.scale)
    }

    /// bc division: the quotient truncated to `scale` fractional digits, or
    /// `nil` for a zero divisor.
    static func divide(_ a: BCNumber, _ b: BCNumber, scale: Int) -> BCNumber? {
        if b.isZero { return nil }
        let shift = scale + b.scale - a.scale
        let numerator = shift >= 0
            ? BCMagnitude.shiftedUp(a.digits, by: shift)
            : BCMagnitude.shiftedDown(a.digits, by: -shift)
        let (quotient, _) = BCMagnitude.divide(numerator, b.digits)
        return BCNumber(negative: a.negative != b.negative, digits: quotient, scale: scale)
    }

    /// bc modulus: `a - (a / b) * b` with the division done at `scale`; the
    /// result has `max(scale + b.scale, a.scale)` fractional digits.
    static func modulo(_ a: BCNumber, _ b: BCNumber, scale: Int) -> BCNumber? {
        guard let quotient = divide(a, b, scale: scale) else { return nil }
        let kept = Swift.max(scale + b.scale, a.scale)
        return subtract(a, multiply(quotient, b, scale: kept)).rescaled(to: kept)
    }

    /// bc exponentiation with an integer exponent. A non-negative power keeps
    /// `min(a.scale × e, max(scale, a.scale))` fractional digits; a negative
    /// one is `1 / a^|e|` at `scale`. `nil` for zero to a negative power.
    static func power(_ a: BCNumber, _ exponent: Int, scale: Int) -> BCNumber? {
        if exponent == 0 { return .one }
        var remaining = exponent.magnitude
        var base = a
        var result = BCNumber.one
        while remaining > 0 {
            if remaining & 1 == 1 { result = multiplyExact(result, base) }
            remaining >>= 1
            if remaining > 0 { base = multiplyExact(base, base) }
        }
        if exponent < 0 { return divide(.one, result, scale: scale) }
        let (wanted, overflow) = a.scale.multipliedReportingOverflow(by: exponent)
        let kept = Swift.min(overflow ? Int.max : wanted, Swift.max(scale, a.scale))
        return result.scale > kept ? result.rescaled(to: kept) : result
    }

    /// Square root with `max(scale, a.scale)` fractional digits; `nil` for a
    /// negative argument.
    static func squareRoot(_ a: BCNumber, scale: Int) -> BCNumber? {
        if a.negative { return nil }
        let kept = Swift.max(scale, a.scale)
        let radicand = BCMagnitude.shiftedUp(a.digits, by: 2 * kept - a.scale)
        return BCNumber(negative: false, digits: BCMagnitude.squareRoot(radicand), scale: kept)
    }

    /// `length(x)`: the number of significant decimal digits.
    var significantDigits: Int {
        if isZero { return Swift.max(1, scale) }
        return Swift.max(digits.count, scale)
    }

    // MARK: Parsing and printing

    /// Parse a bc numeric literal (`[0-9A-F]*[.[0-9A-F]*]`) in `ibase`. A
    /// single-digit literal keeps its face value in any base; otherwise digits
    /// too large for the base are clamped to `ibase - 1`.
    static func parse(_ text: String, ibase: Int) -> BCNumber {
        var whole: [Int] = []
        var fraction: [Int] = []
        var seenPoint = false
        for byte in text.utf8 {
            if byte == 0x2E {
                seenPoint = true
                continue
            }
            let value = byte >= 0x41 ? Int(byte) - 0x41 + 10 : Int(byte) - 0x30
            if seenPoint { fraction.append(value) } else { whole.append(value) }
        }
        let single = whole.count + fraction.count == 1
        func clamp(_ value: Int) -> Int { single ? value : Swift.min(value, ibase - 1) }
        if ibase == 10, !single {
            let all = (whole + fraction).map { UInt8(clamp($0)) }
            return BCNumber(negative: false, digits: all.reversed(), scale: fraction.count)
        }
        var integer: [UInt8] = []
        for value in whole {
            integer = BCMagnitude.add(BCMagnitude.multiply(integer, small: ibase), small: clamp(value))
        }
        var result = BCNumber(negative: false, digits: integer, scale: 0)
        if !fraction.isEmpty {
            var numerator: [UInt8] = []
            var denominator: [UInt8] = [1]
            for value in fraction {
                numerator = BCMagnitude.add(BCMagnitude.multiply(numerator, small: ibase), small: clamp(value))
                denominator = BCMagnitude.multiply(denominator, small: ibase)
            }
            let part = divide(BCNumber(negative: false, digits: numerator, scale: 0),
                              BCNumber(negative: false, digits: denominator, scale: 0),
                              scale: fraction.count) ?? .zero
            result = add(result, part)
        }
        return result
    }

    /// The text bc prints for this number in `obase` (no line wrapping).
    func formatted(obase: Int) -> String {
        if isZero { return "0" }
        var out: [UInt8] = []
        if negative { out.append(0x2D) }
        if obase == 10 {
            let padded = digits + [UInt8](repeating: 0, count: Swift.max(0, scale - digits.count))
            var index = padded.count - 1
            while index >= 0 {
                if index == scale - 1 { out.append(0x2E) }
                out.append(0x30 + padded[index])
                index -= 1
            }
            return String(decoding: out, as: UTF8.self)
        }
        // Width of one digit when the base needs multi-character digits.
        var digitWidth = 0
        if obase > 16 {
            var largest = obase - 1
            while largest > 0 {
                digitWidth += 1
                largest /= 10
            }
        }
        func emit(_ value: Int) {
            if obase <= 16 {
                out.append(value < 10 ? 0x30 + UInt8(value) : 0x41 + UInt8(value - 10))
            } else {
                out.append(0x20)
                let text = Array(String(value).utf8)
                out.append(contentsOf: repeatElement(0x30, count: Swift.max(0, digitWidth - text.count)))
                out.append(contentsOf: text)
            }
        }
        var whole = BCMagnitude.shiftedDown(digits, by: scale)
        var wholeDigits: [Int] = []
        while !whole.isEmpty {
            let (quotient, remainder) = BCMagnitude.divide(whole, small: obase)
            wholeDigits.append(remainder)
            whole = quotient
        }
        for value in wholeDigits.reversed() { emit(value) }
        if scale > 0 {
            out.append(0x2E)
            // Fraction digits are produced until base^k has more integer
            // digits than the scale — GNU bc's stopping rule.
            var fraction = BCMagnitude.trimmed(Array(digits.prefix(scale)))
            var weight: [UInt8] = [1]
            while weight.count <= scale {
                fraction = BCMagnitude.multiply(fraction, small: obase)
                var value = 0
                for digit in BCMagnitude.shiftedDown(fraction, by: scale).reversed() {
                    value = value * 10 + Int(digit)
                }
                emit(value)
                fraction = BCMagnitude.trimmed(Array(fraction.prefix(scale)))
                weight = BCMagnitude.multiply(weight, small: obase)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Math library (-l)

/// The `bc -l` functions, computed with the classic series at a raised working
/// scale and truncated to the caller's scale.
private enum BCMath {

    private static func mul(_ a: BCNumber, _ b: BCNumber, _ scale: Int) -> BCNumber {
        BCNumber.multiply(a, b, scale: scale)
    }

    private static func div(_ a: BCNumber, _ b: BCNumber, _ scale: Int) -> BCNumber {
        BCNumber.divide(a, b, scale: scale) ?? .zero
    }

    private static let two = BCNumber(2)
    private static let fifth = BCNumber.parse(".2", ibase: 10)
    private static let half = BCNumber.parse(".5", ibase: 10)

    /// e^x.
    static func exponential(_ argument: BCNumber, scale: Int) -> BCNumber {
        var x = argument
        let inverted = x.negative
        if inverted { x = x.negated }
        let magnitude = Swift.min(x.integerValue ?? 100_000, 100_000)
        let working = 6 + scale + magnitude * 44 / 100
        var squarings = 0
        while BCNumber.compare(x, .one) > 0 {
            squarings += 1
            x = div(x, two, working)
        }
        var value = BCNumber.add(.one, x)
        var term = x
        var factorial = BCNumber.one
        var index = 2
        while true {
            term = mul(term, x, working)
            factorial = mul(factorial, BCNumber(index), working)
            let delta = div(term, factorial, working)
            if delta.isZero { break }
            value = BCNumber.add(value, delta)
            index += 1
        }
        for _ in 0..<squarings { value = mul(value, value, working) }
        return inverted ? div(.one, value, scale) : div(value, .one, scale)
    }

    /// Natural logarithm; a non-positive argument yields `1 - 10^scale` like GNU bc.
    static func logarithm(_ argument: BCNumber, scale: Int) -> BCNumber {
        if argument.isZero || argument.negative {
            let big = BCNumber.power(BCNumber(10), scale, scale: 0) ?? .one
            return BCNumber.subtract(.one, big)
        }
        let working = 6 + scale
        var x = argument
        var factor = BCNumber(2)
        while BCNumber.compare(x, two) >= 0 {
            factor = BCNumber.multiplyExact(factor, two)
            x = BCNumber.squareRoot(x, scale: working) ?? x
        }
        while BCNumber.compare(x, half) <= 0 {
            factor = BCNumber.multiplyExact(factor, two)
            x = BCNumber.squareRoot(x, scale: working) ?? x
        }
        var term = div(BCNumber.subtract(x, .one), BCNumber.add(x, .one), working)
        var value = term
        let square = mul(term, term, working)
        var index = 3
        while true {
            term = mul(term, square, working)
            let delta = div(term, BCNumber(index), working)
            if delta.isZero { break }
            value = BCNumber.add(value, delta)
            index += 2
        }
        return div(mul(factor, value, working), .one, scale)
    }

    /// Arctangent.
    static func arctangent(_ argument: BCNumber, scale: Int) -> BCNumber {
        var x = argument
        let negative = x.negative
        if negative { x = x.negated }
        var reference = BCNumber.zero
        if BCNumber.compare(x, fifth) > 0 {
            reference = arctangent(fifth, scale: scale + 5)
        }
        let working = scale + 3
        var reductions = 0
        while BCNumber.compare(x, fifth) > 0 {
            reductions += 1
            x = div(BCNumber.subtract(x, fifth), BCNumber.add(.one, mul(x, fifth, working)), working)
        }
        var term = x
        var value = x
        let square = mul(x.negated, x, working)
        var index = 3
        while true {
            term = mul(term, square, working)
            let delta = div(term, BCNumber(index), working)
            if delta.isZero { break }
            value = BCNumber.add(value, delta)
            index += 2
        }
        let total = BCNumber.add(BCNumber.multiplyExact(BCNumber(reductions), reference), value)
        return div(negative ? total.negated : total, .one, scale)
    }

    /// Sine.
    static func sine(_ argument: BCNumber, scale: Int) -> BCNumber {
        var x = argument
        let negative = x.negative
        if negative { x = x.negated }
        let quarterPi = arctangent(.one, scale: scale * 11 / 10 + 2)
        // Reduce by multiples of pi: n = (x / (pi/4) + 2) / 4, x -= 4·n·(pi/4).
        let turns = div(BCNumber.add(div(x, quarterPi, 0), two), BCNumber(4), 0)
        x = BCNumber.subtract(x, BCNumber.multiplyExact(BCNumber.multiplyExact(BCNumber(4), turns), quarterPi))
        if let last = turns.digits.first, last % 2 == 1 { x = x.negated }
        let working = scale + 2
        var term = x
        var value = x
        let square = mul(x.negated, x, working)
        var index = 3
        while true {
            term = mul(term, div(square, BCNumber(index * (index - 1)), working), working)
            if term.isZero { break }
            value = BCNumber.add(value, term)
            index += 2
        }
        return div(negative ? value.negated : value, .one, scale)
    }

    /// Cosine, as `sin(x + pi/2)`.
    static func cosine(_ argument: BCNumber, scale: Int) -> BCNumber {
        let working = scale * 12 / 10
        let halfPi = BCNumber.multiplyExact(arctangent(.one, scale: working), two)
        return div(sine(BCNumber.add(argument, halfPi), scale: working), .one, scale)
    }
}

// MARK: - Lexer

private enum BCToken: Equatable {
    case number(String)
    case name(String)
    case string(String)
    case symbol(String)
    case newline
    case end
}

private enum BCSyntaxError: Error {
    /// The text ends inside a construct that more input could complete.
    case incomplete
    /// A syntax error on the given 1-based line of the parsed text.
    case invalid(line: Int, message: String)
}

private struct BCLexer {
    private let bytes: [UInt8]
    private var position = 0
    private var line = 1

    init(_ text: [UInt8]) { bytes = text }

    private static let symbols2: Set<String> = [
        "+=", "-=", "*=", "/=", "%=", "^=", "==", "!=", "<=", ">=", "&&", "||", "++", "--",
    ]
    private static let symbols1 = Set("+-*/%^(){}[],;=<>!".map(String.init))

    /// All tokens with their line numbers, ending with `.end`.
    mutating func tokenize() throws -> [(token: BCToken, line: Int)] {
        var tokens: [(BCToken, Int)] = []
        while position < bytes.count {
            let byte = bytes[position]
            if byte == 0x0A {
                tokens.append((.newline, line))
                line += 1
                position += 1
            } else if byte == 0x20 || byte == 0x09 || byte == 0x0D {
                position += 1
            } else if byte == 0x5C, position + 1 < bytes.count, bytes[position + 1] == 0x0A {
                position += 2                              // line continuation
                line += 1
            } else if byte == 0x23 {
                while position < bytes.count, bytes[position] != 0x0A { position += 1 }
            } else if byte == 0x2F, position + 1 < bytes.count, bytes[position + 1] == 0x2A {
                position += 2
                while true {
                    guard position + 1 < bytes.count else { throw BCSyntaxError.incomplete }
                    if bytes[position] == 0x2A, bytes[position + 1] == 0x2F { break }
                    if bytes[position] == 0x0A { line += 1 }
                    position += 1
                }
                position += 2
            } else if byte == 0x22 {
                let startLine = line
                position += 1
                let start = position
                while true {
                    guard position < bytes.count else { throw BCSyntaxError.incomplete }
                    if bytes[position] == 0x22 { break }
                    if bytes[position] == 0x0A { line += 1 }
                    position += 1
                }
                tokens.append((.string(String(decoding: bytes[start..<position], as: UTF8.self)), startLine))
                position += 1
            } else if isDigit(byte) || byte == 0x2E {
                var text: [UInt8] = []
                while position < bytes.count {
                    let current = bytes[position]
                    if isDigit(current) || current == 0x2E {
                        text.append(current)
                        position += 1
                    } else if current == 0x5C, position + 1 < bytes.count, bytes[position + 1] == 0x0A {
                        position += 2
                        line += 1
                    } else {
                        break
                    }
                }
                let literal = String(decoding: text, as: UTF8.self)
                guard literal.utf8.filter({ $0 == 0x2E }).count <= 1 else {
                    throw BCSyntaxError.invalid(line: line, message: "syntax error")
                }
                // A lone `.` is the last printed value.
                tokens.append((literal == "." ? .name("last") : .number(literal), line))
            } else if byte >= 0x61, byte <= 0x7A {
                let start = position
                while position < bytes.count,
                      (bytes[position] >= 0x61 && bytes[position] <= 0x7A)
                        || (bytes[position] >= 0x30 && bytes[position] <= 0x39) || bytes[position] == 0x5F {
                    position += 1
                }
                tokens.append((.name(String(decoding: bytes[start..<position], as: UTF8.self)), line))
            } else {
                let two = position + 1 < bytes.count
                    ? String(decoding: bytes[position...(position + 1)], as: UTF8.self) : ""
                let one = String(decoding: [byte], as: UTF8.self)
                if Self.symbols2.contains(two) {
                    tokens.append((.symbol(two), line))
                    position += 2
                } else if Self.symbols1.contains(one) {
                    tokens.append((.symbol(one), line))
                    position += 1
                } else {
                    throw BCSyntaxError.invalid(line: line, message: "illegal character: \(one)")
                }
            }
        }
        tokens.append((.end, line))
        return tokens
    }

    /// Digits of a numeric literal: `0-9` and the upper-case hex digits.
    private func isDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46)
    }
}

// MARK: - Syntax tree

private enum BCTarget {
    case variable(String)
    indirect case element(String, BCExpression)
}

private indirect enum BCExpression {
    case number(String)
    case load(BCTarget)
    case assign(BCTarget, operation: String?, BCExpression)
    case step(BCTarget, delta: Int, prefix: Bool)
    case negate(BCExpression)
    case not(BCExpression)
    case binary(String, BCExpression, BCExpression)
    case call(String, [BCExpression])
    case builtin(String, BCExpression)
    case group(BCExpression)
}

private enum BCPrintItem {
    case text(String)
    case value(BCExpression)
}

private struct BCFunction {
    var name: String
    var parameters: [String]
    var locals: [String]
    var body: [BCStatement]
}

private indirect enum BCStatement {
    case expression(BCExpression)
    case text(String)
    case print([BCPrintItem])
    case block([BCStatement])
    case conditional(BCExpression, BCStatement, BCStatement?)
    case whileLoop(BCExpression, BCStatement)
    case forLoop(BCExpression?, BCExpression?, BCExpression?, BCStatement)
    case breakLoop
    case continueLoop
    case returnValue(BCExpression?)
    case define(BCFunction)
    case halt
    case quit
}

// MARK: - Parser

private struct BCParser {
    private let tokens: [(token: BCToken, line: Int)]
    private var index = 0
    private var depth = 0
    /// Set when `quit` appears inside a compound statement or function body —
    /// bc acts on `quit` when it is read, not when it would be executed.
    private(set) var nestedQuit = false

    init(_ text: [UInt8]) throws {
        var lexer = BCLexer(text)
        tokens = try lexer.tokenize()
    }

    private static let keywords: Set<String> = [
        "if", "else", "while", "for", "break", "continue", "return", "define", "auto",
        "quit", "halt", "print", "length", "sqrt",
    ]

    private var current: BCToken { tokens[index].token }

    private func failure() -> BCSyntaxError {
        if current == .end { return .incomplete }
        return .invalid(line: tokens[index].line, message: "syntax error")
    }

    /// A syntax error that more input cannot fix, even at the end of the text.
    private func hardFailure() -> BCSyntaxError {
        .invalid(line: tokens[index].line, message: "syntax error")
    }

    private mutating func accept(_ symbol: String) -> Bool {
        if current == .symbol(symbol) {
            index += 1
            return true
        }
        return false
    }

    private mutating func expect(_ symbol: String) throws {
        guard accept(symbol) else {
            // Inside (...) the end of a line is an error, not a continuation.
            throw current == .end && depth > 0 ? failure() : hardFailure()
        }
    }

    private mutating func skipNewlines() {
        while current == .newline { index += 1 }
    }

    /// Parse the whole text as a list of top-level statements.
    mutating func parseProgram() throws -> [BCStatement] {
        var statements: [BCStatement] = []
        while true {
            while current == .newline || current == .symbol(";") { index += 1 }
            if current == .end { return statements }
            statements.append(try parseStatement())
            guard current == .newline || current == .symbol(";") || current == .end else {
                throw hardFailure()
            }
        }
    }

    private mutating func parseBlock() throws -> [BCStatement] {
        depth += 1
        defer { depth -= 1 }
        var statements: [BCStatement] = []
        while true {
            while current == .newline || current == .symbol(";") { index += 1 }
            if accept("}") { return statements }
            if current == .end { throw BCSyntaxError.incomplete }
            statements.append(try parseStatement())
            guard current == .newline || current == .symbol(";") || current == .symbol("}")
                    || current == .end else {
                throw hardFailure()
            }
        }
    }

    /// The statement after an `if`/`while`/`for` header or `else`, which may
    /// start on a following line.
    private mutating func parseBody() throws -> BCStatement {
        skipNewlines()
        if current == .end { throw BCSyntaxError.incomplete }
        depth += 1
        defer { depth -= 1 }
        return try parseStatement()
    }

    private mutating func parseStatement() throws -> BCStatement {
        if accept("{") { return .block(try parseBlock()) }
        if case let .string(text) = current {
            index += 1
            return .text(text)
        }
        guard case let .name(word) = current, Self.keywords.contains(word),
              word != "length", word != "sqrt" else {
            return .expression(try parseExpression())
        }
        index += 1
        switch word {
        case "if":
            try expect("(")
            let condition = try parseExpression()
            try expect(")")
            let body = try parseBody()
            var alternative: BCStatement? = nil
            if current == .name("else") {
                index += 1
                alternative = try parseBody()
            }
            return .conditional(condition, body, alternative)
        case "while":
            try expect("(")
            let condition = try parseExpression()
            try expect(")")
            return .whileLoop(condition, try parseBody())
        case "for":
            try expect("(")
            let initial = current == .symbol(";") ? nil : try parseExpression()
            try expect(";")
            let condition = current == .symbol(";") ? nil : try parseExpression()
            try expect(";")
            let update = current == .symbol(")") ? nil : try parseExpression()
            try expect(")")
            return .forLoop(initial, condition, update, try parseBody())
        case "break":
            return .breakLoop
        case "continue":
            return .continueLoop
        case "halt":
            return .halt
        case "quit":
            if depth > 0 { nestedQuit = true }
            return .quit
        case "return":
            if current == .newline || current == .symbol(";") || current == .symbol("}") || current == .end {
                return .returnValue(nil)
            }
            return .returnValue(try parseExpression())
        case "print":
            var items: [BCPrintItem] = []
            repeat {
                if case let .string(text) = current {
                    index += 1
                    items.append(.text(text))
                } else {
                    items.append(.value(try parseExpression()))
                }
            } while accept(",")
            return .print(items)
        case "define":
            guard depth == 0, case let .name(name) = current, !Self.keywords.contains(name) else {
                throw hardFailure()
            }
            index += 1
            try expect("(")
            var parameters: [String] = []
            if !accept(")") {
                repeat {
                    guard case let .name(parameter) = current, !Self.keywords.contains(parameter) else {
                        throw hardFailure()
                    }
                    index += 1
                    parameters.append(parameter)
                } while accept(",")
                try expect(")")
            }
            skipNewlines()
            if current == .end { throw BCSyntaxError.incomplete }
            try expect("{")
            depth += 1
            defer { depth -= 1 }
            skipNewlines()
            var locals: [String] = []
            if current == .name("auto") {
                index += 1
                repeat {
                    guard case let .name(local) = current, !Self.keywords.contains(local) else {
                        throw failure()
                    }
                    index += 1
                    locals.append(local)
                } while accept(",")
                guard current == .newline || current == .symbol(";") else { throw failure() }
            }
            let body = try parseBlock()
            return .define(BCFunction(name: name, parameters: parameters, locals: locals, body: body))
        default:
            throw hardFailure()          // a stray `else` or `auto`
        }
    }

    // Precedence, lowest first: || && ! relational assignment + - * / % ^
    // unary-minus ++/--.

    private mutating func parseExpression() throws -> BCExpression {
        var left = try parseAnd()
        while accept("||") { left = .binary("||", left, try parseAnd()) }
        return left
    }

    private mutating func parseAnd() throws -> BCExpression {
        var left = try parseNot()
        while accept("&&") { left = .binary("&&", left, try parseNot()) }
        return left
    }

    private mutating func parseNot() throws -> BCExpression {
        if accept("!") { return .not(try parseNot()) }
        return try parseRelational()
    }

    private mutating func parseRelational() throws -> BCExpression {
        var left = try parseAdditive()
        while case let .symbol(symbol) = current,
              ["==", "!=", "<", "<=", ">", ">="].contains(symbol) {
            index += 1
            left = .binary(symbol, left, try parseAdditive())
        }
        return left
    }

    private mutating func parseAdditive() throws -> BCExpression {
        var left = try parseMultiplicative()
        while case let .symbol(symbol) = current, symbol == "+" || symbol == "-" {
            index += 1
            left = .binary(symbol, left, try parseMultiplicative())
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> BCExpression {
        var left = try parsePower()
        while case let .symbol(symbol) = current, symbol == "*" || symbol == "/" || symbol == "%" {
            index += 1
            left = .binary(symbol, left, try parsePower())
        }
        return left
    }

    private mutating func parsePower() throws -> BCExpression {
        let base = try parseUnary()
        if accept("^") { return .binary("^", base, try parsePower()) }
        return base
    }

    private mutating func parseUnary() throws -> BCExpression {
        if accept("-") { return .negate(try parseUnary()) }
        return try parsePrimary()
    }

    private mutating func parseTarget(_ name: String) throws -> BCTarget {
        if accept("[") {
            let subscriptExpression = try parseExpression()
            try expect("]")
            return .element(name, subscriptExpression)
        }
        return .variable(name)
    }

    private mutating func parsePrimary() throws -> BCExpression {
        if case let .number(text) = current {
            index += 1
            return .number(text)
        }
        if accept("(") {
            depth += 1
            defer { depth -= 1 }
            let inner = try parseExpression()
            try expect(")")
            return .group(inner)
        }
        if case let .symbol(symbol) = current, symbol == "++" || symbol == "--" {
            index += 1
            guard case let .name(name) = current, !Self.keywords.contains(name) else { throw failure() }
            index += 1
            return .step(try parseTarget(name), delta: symbol == "++" ? 1 : -1, prefix: true)
        }
        guard case let .name(name) = current else { throw failure() }
        if name == "length" || name == "sqrt" || (name == "scale" && tokens[index + 1].token == .symbol("(")) {
            index += 1
            try expect("(")
            let argument = try parseExpression()
            try expect(")")
            return .builtin(name, argument)
        }
        guard !Self.keywords.contains(name) else { throw hardFailure() }
        index += 1
        if accept("(") {
            var arguments: [BCExpression] = []
            if !accept(")") {
                repeat { arguments.append(try parseExpression()) } while accept(",")
                try expect(")")
            }
            return .call(name, arguments)
        }
        let target = try parseTarget(name)
        if case let .symbol(symbol) = current {
            if symbol == "=" {
                index += 1
                return .assign(target, operation: nil, try parseAdditive())
            }
            if symbol.count == 2, symbol.hasSuffix("="), "+-*/%^".contains(symbol.first!) {
                index += 1
                return .assign(target, operation: String(symbol.first!), try parseAdditive())
            }
            if symbol == "++" || symbol == "--" {
                index += 1
                return .step(target, delta: symbol == "++" ? 1 : -1, prefix: false)
            }
        }
        return .load(target)
    }
}

// MARK: - Interpreter

/// Evaluates parsed bc statements against one calculator session's state
/// (variables, arrays, functions, `scale` / `ibase` / `obase`, `last`).
///
/// Concurrency: owned by the `bc` command body and touched only from it on the
/// loop-bound executor.
private final class BCInterpreter {

    enum Stop: Error {
        /// A runtime error was reported; abandon the current statement group.
        case runtimeError
        /// `halt` was executed, or the process is going away.
        case halt
    }

    private enum Flow {
        case normal
        case breakLoop
        case continueLoop
        case returned(BCNumber)
    }

    private let ctx: ProcessContext
    private let mathLibrary: Bool
    private var variables: [String: BCNumber] = [:]
    private var arrays: [String: [Int: BCNumber]] = [:]
    private var functions: [String: BCFunction] = [:]
    private var scale: Int
    private var inputBase = 10
    private var outputBase = 10
    private var last = BCNumber.zero
    /// Standard output accumulated since the last flush.
    private var output: [UInt8] = []
    /// Characters on the current output line, for the 70-column wrap.
    private var column = 0
    private var functionName = "(main)"
    /// A stand-in for GNU bc's byte-code address in diagnostics: the size of
    /// the code a straight-line statement group would have compiled to so far.
    private var address = 0
    private var callDepth = 0
    private var iterations = 0

    init(_ ctx: ProcessContext, mathLibrary: Bool) {
        self.ctx = ctx
        self.mathLibrary = mathLibrary
        self.scale = mathLibrary ? 20 : 0
    }

    // MARK: Output

    /// Write pending output; `false` when the reader is gone.
    func flush() async -> Bool {
        guard !output.isEmpty else { return true }
        let bytes = output
        output.removeAll(keepingCapacity: true)
        return await ctx.put(bytes)
    }

    private func emit(text: String) {
        for byte in text.utf8 {
            output.append(byte)
            column = byte == 0x0A ? 0 : column + 1
        }
    }

    /// Print a number, breaking long ones with `\` + newline so no line
    /// exceeds 70 columns (GNU bc's default line length).
    private func emit(number: BCNumber) {
        for byte in number.formatted(obase: outputBase).utf8 {
            column += 1
            if column == 69 {
                output.append(contentsOf: [0x5C, 0x0A])
                column = 1
            }
            output.append(byte)
        }
    }

    private func runtimeError(_ message: String) -> Stop {
        ctx.error("Runtime error (func=\(functionName), adr=\(address)): \(message)")
        return .runtimeError
    }

    private func warning(_ message: String) {
        ctx.error("Runtime warning (func=\(functionName), adr=\(address)): \(message)")
    }

    // MARK: Statements

    /// Run one group of top-level statements. Returns `false` when the session
    /// should end (`quit`, `halt`, or the output reader went away).
    func run(_ statements: [BCStatement]) async -> Bool {
        address = 0
        functionName = "(main)"
        callDepth = 0
        do {
            for statement in statements {
                if case .quit = statement {
                    _ = await flush()
                    return false
                }
                _ = try await execute(statement)
            }
        } catch Stop.halt {
            _ = await flush()
            return false
        } catch {
            // A runtime error abandons the rest of this group only.
        }
        return await flush()
    }

    /// Give the event loop a turn inside long-running loops, and push output
    /// through so a pipeline reader sees it as it is produced.
    ///
    /// The first iteration yields too. Evaluation suspends at every `async`
    /// call, and until its first yield that is ordinary work the event loop
    /// waits for; yielding at once keeps a long loop from holding logical
    /// time through its first 256 iterations.
    private func yieldPeriodically() async throws {
        iterations += 1
        guard iterations % 256 == 1 || output.count >= 16384 else { return }
        guard await flush() else { throw Stop.halt }
        do {
            try await ctx.yield()
        } catch {
            throw Stop.halt
        }
    }

    private func execute(_ statement: BCStatement) async throws -> Flow {
        switch statement {
        case let .expression(expression):
            let value = try await evaluate(expression)
            if case .assign = expression { return .normal }
            address += 1
            emit(number: value)
            emit(text: "\n")
            last = value
        case let .text(text):
            emit(text: text)
        case let .print(items):
            for item in items {
                switch item {
                case let .text(text):
                    emit(text: Self.unescaped(text))
                case let .value(expression):
                    let value = try await evaluate(expression)
                    emit(number: value)
                    last = value
                }
            }
        case let .block(statements):
            for inner in statements {
                let flow = try await execute(inner)
                if case .normal = flow { continue }
                return flow
            }
        case let .conditional(condition, body, alternative):
            if !(try await evaluate(condition)).isZero {
                return try await execute(body)
            } else if let alternative {
                return try await execute(alternative)
            }
        case let .whileLoop(condition, body):
            while !(try await evaluate(condition)).isZero {
                let flow = try await execute(body)
                if case .breakLoop = flow { break }
                if case .returned = flow { return flow }
                try await yieldPeriodically()
            }
        case let .forLoop(initial, condition, update, body):
            if let initial { _ = try await evaluate(initial) }
            while true {
                if let condition, (try await evaluate(condition)).isZero { break }
                let flow = try await execute(body)
                if case .breakLoop = flow { break }
                if case .returned = flow { return flow }
                if let update { _ = try await evaluate(update) }
                try await yieldPeriodically()
            }
        case .breakLoop:
            return .breakLoop
        case .continueLoop:
            return .continueLoop
        case let .returnValue(expression):
            if let expression { return .returned(try await evaluate(expression)) }
            return .returned(.zero)
        case let .define(function):
            functions[function.name] = function
        case .halt, .quit:
            throw Stop.halt
        }
        return .normal
    }

    /// The escapes `print` understands in its string arguments.
    private static func unescaped(_ text: String) -> String {
        var out = ""
        var escaped = false
        for character in text {
            if escaped {
                switch character {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "a": out.append("\u{07}")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "q": out.append("\"")
                case "\\": out.append("\\")
                default:
                    out.append("\\")
                    out.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    // MARK: Variables

    private func subscriptValue(_ expression: BCExpression) async throws -> Int {
        let value = try await evaluate(expression)
        guard let index = value.integerValue, index >= 0, index < 16_777_216 else {
            throw runtimeError("Array index out of bounds.")
        }
        return index
    }

    /// Resolve an lvalue's subscript once, so `a[i++] += 1` evaluates it once.
    private func resolve(_ target: BCTarget) async throws -> (name: String, index: Int?) {
        switch target {
        case let .variable(name):
            return (name, nil)
        case let .element(name, expression):
            return (name, try await subscriptValue(expression))
        }
    }

    private func load(_ name: String, _ index: Int?) -> BCNumber {
        if let index { return arrays[name]?[index] ?? .zero }
        if name == "scale" { return BCNumber(scale) }
        if name == "ibase" { return BCNumber(inputBase) }
        if name == "obase" { return BCNumber(outputBase) }
        if name == "last" { return last }
        return variables[name] ?? .zero
    }

    private func store(_ name: String, _ index: Int?, _ value: BCNumber) {
        if let index {
            arrays[name, default: [:]][index] = value
            return
        }
        if name == "scale" {
            if value.negative {
                warning("negative scale, set to 0")
                scale = 0
            } else {
                scale = Swift.min(value.integerValue ?? 65535, 65535)
            }
        } else if name == "ibase" {
            let base = value.negative ? 0 : (value.integerValue ?? Int.max)
            if base < 2 {
                warning("ibase too small, set to 2")
                inputBase = 2
            } else if base > 16 {
                warning("ibase too large, set to 16")
                inputBase = 16
            } else {
                inputBase = base
            }
        } else if name == "obase" {
            let base = value.negative ? 0 : (value.integerValue ?? Int.max)
            if base < 2 {
                warning("obase too small, set to 2")
                outputBase = 2
            } else if base > 999_999_999 {
                warning("obase too large, set to 999999999")
                outputBase = 999_999_999
            } else {
                outputBase = base
            }
        } else if name == "last" {
            last = value
        } else {
            variables[name] = value
        }
    }

    // MARK: Expressions

    private func apply(_ operation: String, _ left: BCNumber, _ right: BCNumber) throws -> BCNumber {
        address += 1
        switch operation {
        case "+":
            return BCNumber.add(left, right)
        case "-":
            return BCNumber.subtract(left, right)
        case "*":
            return BCNumber.multiply(left, right, scale: scale)
        case "/":
            guard let result = BCNumber.divide(left, right, scale: scale) else {
                throw runtimeError("Divide by zero")
            }
            return result
        case "%":
            guard let result = BCNumber.modulo(left, right, scale: scale) else {
                throw runtimeError("Modulo by zero")
            }
            return result
        case "^":
            if right.scale > 0, right != right.integerPart.rescaled(to: right.scale) {
                warning("non-zero scale in exponent")
            }
            guard let exponent = right.integerValue, exponent.magnitude <= 100_000_000 else {
                throw runtimeError("exponent too large in raise")
            }
            if left.isZero, exponent < 0 { throw runtimeError("Divide by zero") }
            guard let result = BCNumber.power(left, exponent, scale: scale) else {
                throw runtimeError("Divide by zero")
            }
            return result
        default:
            let order = BCNumber.compare(left, right)
            let truth: Bool
            switch operation {
            case "==": truth = order == 0
            case "!=": truth = order != 0
            case "<": truth = order < 0
            case "<=": truth = order <= 0
            case ">": truth = order > 0
            default: truth = order >= 0
            }
            return truth ? .one : .zero
        }
    }

    private func evaluate(_ expression: BCExpression) async throws -> BCNumber {
        switch expression {
        case let .number(text):
            address += text == "0" || text == "1" ? 1 : text.utf8.count + 2
            return BCNumber.parse(text, ibase: inputBase)
        case let .group(inner):
            return try await evaluate(inner)
        case let .load(target):
            let (name, index) = try await resolve(target)
            address += 2
            return load(name, index)
        case let .assign(target, operation, valueExpression):
            let (name, index) = try await resolve(target)
            var value = try await evaluate(valueExpression)
            if let operation {
                address += 2
                value = try apply(operation, load(name, index), value)
            }
            address += 2
            store(name, index, value)
            return value
        case let .step(target, delta, prefix):
            let (name, index) = try await resolve(target)
            let old = load(name, index)
            let new = BCNumber.add(old, BCNumber(delta))
            address += 4
            store(name, index, new)
            return prefix ? new : old
        case let .negate(inner):
            let value = try await evaluate(inner)
            address += 1
            return value.negated
        case let .not(inner):
            let value = try await evaluate(inner)
            address += 1
            return value.isZero ? .one : .zero
        case let .binary(operation, leftExpression, rightExpression):
            let left = try await evaluate(leftExpression)
            if operation == "&&" || operation == "||" {
                // bc evaluates both operands (no short circuit).
                let right = try await evaluate(rightExpression)
                address += 1
                let truth = operation == "&&" ? !left.isZero && !right.isZero : !left.isZero || !right.isZero
                return truth ? .one : .zero
            }
            let right = try await evaluate(rightExpression)
            return try apply(operation, left, right)
        case let .builtin(name, argumentExpression):
            let argument = try await evaluate(argumentExpression)
            address += 2
            if name == "length" { return BCNumber(argument.significantDigits) }
            if name == "scale" { return BCNumber(argument.scale) }
            guard let root = BCNumber.squareRoot(argument, scale: scale) else {
                throw runtimeError("Square root of a negative number")
            }
            return root
        case let .call(name, argumentExpressions):
            var arguments: [BCNumber] = []
            for argumentExpression in argumentExpressions {
                arguments.append(try await evaluate(argumentExpression))
            }
            address += 3
            return try await call(name, arguments)
        }
    }

    private func call(_ name: String, _ arguments: [BCNumber]) async throws -> BCNumber {
        guard let function = functions[name] else {
            if mathLibrary, arguments.count == 1, let result = mathFunction(name, arguments[0]) {
                return result
            }
            throw runtimeError("Function \(name) not defined.")
        }
        guard function.parameters.count == arguments.count else {
            throw runtimeError("Parameter number mismatch")
        }
        guard callDepth < 2000 else {
            throw runtimeError("Function call depth exceeded")
        }
        // bc scoping is dynamic: parameters and `auto` locals shadow the
        // globals of the same name for the duration of the call.
        let shadowed = function.parameters + function.locals
        let saved = shadowed.map { variables[$0] }
        for (parameter, argument) in zip(function.parameters, arguments) { variables[parameter] = argument }
        for local in function.locals { variables[local] = .zero }
        let savedName = functionName
        let savedAddress = address
        functionName = name
        address = 0
        callDepth += 1
        defer {
            for (shadowedName, value) in zip(shadowed, saved) { variables[shadowedName] = value }
            functionName = savedName
            address = savedAddress
            callDepth -= 1
        }
        try await yieldPeriodically()
        for statement in function.body {
            let flow = try await execute(statement)
            if case let .returned(value) = flow { return value }
        }
        return .zero
    }

    private func mathFunction(_ name: String, _ argument: BCNumber) -> BCNumber? {
        if name == "s" { return BCMath.sine(argument, scale: scale) }
        if name == "c" { return BCMath.cosine(argument, scale: scale) }
        if name == "a" { return BCMath.arctangent(argument, scale: scale) }
        if name == "l" { return BCMath.logarithm(argument, scale: scale) }
        if name == "e" { return BCMath.exponential(argument, scale: scale) }
        return nil
    }
}

// MARK: - Command

extension BuiltinCommands {

    static func calculatorCommands() -> [Command] {
        [
            Command(name: "bc", summary: "arbitrary-precision calculator language", category: .text, usage: """
                bc [-l] [-q] [FILE]...
                  -l  load the math library (s, c, a, l, e) and set scale to 20
                  -q  quiet (accepted for compatibility; no banner is ever printed)
                  Reads the FILEs, then standard input. Each expression's value is printed on its own line.
                  Operators: + - * / % ^, ++ --, = += -= *= /= %= ^=, == != < <= > >=, ! && ||
                  Special variables: scale, ibase, obase, last (also written '.')
                  Functions: sqrt(x), length(x), scale(x); define f(a, b) { auto t; ...; return (x); }
                  Statements: if (c) s [else s], while (c) s, for (i; c; u) s, break, continue, print, halt, quit
                """, asyncRun: { ctx, argv in
                guard let opts = ctx.options("bc", Array(argv.dropFirst()), "lqsw",
                                             long: ["mathlib": "l", "quiet": "q", "standard": "s",
                                                    "warn": "w"]) else { return }
                let interpreter = BCInterpreter(ctx, mathLibrary: opts.has("l"))
                var pending: [UInt8] = []
                var pendingLine = 1

                /// Feed one source line; `false` ends the session.
                func feed(_ line: [UInt8], number: Int, source: String) async -> Bool {
                    if pending.isEmpty { pendingLine = number }
                    pending.append(contentsOf: line)
                    pending.append(0x0A)
                    do {
                        var parser = try BCParser(pending)
                        let program = try parser.parseProgram()
                        pending.removeAll(keepingCapacity: true)
                        if parser.nestedQuit { return false }
                        return await interpreter.run(program)
                    } catch BCSyntaxError.incomplete {
                        return true
                    } catch let BCSyntaxError.invalid(line, message) {
                        ctx.error("\(source) \(pendingLine + line - 1): \(message)")
                        pending.removeAll(keepingCapacity: true)
                        return true
                    } catch {
                        pending.removeAll(keepingCapacity: true)
                        return true
                    }
                }

                for path in opts.operands {
                    let text: [UInt8]
                    do {
                        text = try await readOperand(ctx, path)
                    } catch {
                        ctx.fail("File \(path) is unavailable.", code: 1)
                        return
                    }
                    var lines = text.split(separator: 0x0A, omittingEmptySubsequences: false)
                    if lines.last?.isEmpty == true { lines.removeLast() }
                    for (index, line) in lines.enumerated() {
                        guard await feed(Array(line), number: index + 1, source: path) else {
                            ctx.exit(0)
                            return
                        }
                    }
                    if !pending.isEmpty {
                        ctx.error("\(path) \(lines.count): syntax error")
                        pending.removeAll(keepingCapacity: true)
                    }
                }

                let input = CommandInput(ctx, command: "bc", files: ["-"])
                var number = 0
                while let line = await input.line() {
                    number += 1
                    guard await feed(line, number: number, source: "(standard_in)") else {
                        ctx.exit(0)
                        return
                    }
                }
                if !pending.isEmpty {
                    ctx.error("(standard_in) \(number): syntax error")
                }
                ctx.exit(0)
            }),
        ]
    }
}
