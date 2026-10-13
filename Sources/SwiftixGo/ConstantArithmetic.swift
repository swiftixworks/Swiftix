/// Exact integer and rational arithmetic for the constants of a Go program.
///
/// Go evaluates constant expressions exactly: an untyped constant is an
/// integer or a fraction of any size, and it is rounded only when it is
/// converted to a sized type. The types here hold such values, and every
/// operation computes what `math/big` computes for the same operands, because
/// that is the arithmetic the Go compiler itself uses.
///
/// Nothing here traps. An operation that has no answer, such as a division by
/// zero, returns nil instead.

/// Arithmetic on magnitudes, the unsigned halves of the integers.
///
/// A magnitude is an array of 32-bit limbs, least significant first, whose
/// last limb is not zero, so zero is the empty array and every value has
/// exactly one form. Limbs are 32 bits wide so that the product of two limbs
/// plus two more limbs always fits in a `UInt64`, which keeps every step
/// free of overflow without any special care.
private enum Magnitude {
    typealias Limbs = [UInt32]

    /// Removes zero limbs from the top, which restores the one form that
    /// comparison and hashing rely on.
    static func trimmed(_ limbs: Limbs) -> Limbs {
        var result = limbs
        while let top = result.last, top == 0 {
            result.removeLast()
        }
        return result
    }

    static func limbs(of value: UInt64) -> Limbs {
        trimmed([UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)])
    }

    /// The low 64 bits, which is the whole value when there are at most two
    /// limbs.
    static func lowBits(_ limbs: Limbs) -> UInt64 {
        let low = limbs.count > 0 ? UInt64(limbs[0]) : 0
        let high = limbs.count > 1 ? UInt64(limbs[1]) : 0
        return (high << 32) | low
    }

    static func bitWidth(_ limbs: Limbs) -> Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 32 - top.leadingZeroBitCount
    }

    /// -1, 0, or 1 as `lhs` is below, equal to, or above `rhs`. With no zero
    /// limbs at the top, the longer magnitude is the larger one.
    static func compare(_ lhs: Limbs, _ rhs: Limbs) -> Int {
        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? -1 : 1
        }
        var index = lhs.count
        while index > 0 {
            index -= 1
            if lhs[index] != rhs[index] {
                return lhs[index] < rhs[index] ? -1 : 1
            }
        }
        return 0
    }

    static func sum(_ lhs: Limbs, _ rhs: Limbs) -> Limbs {
        let (long, short) = lhs.count >= rhs.count ? (lhs, rhs) : (rhs, lhs)
        var result = Limbs()
        result.reserveCapacity(long.count + 1)
        var carry: UInt64 = 0
        for index in long.indices {
            let addend = index < short.count ? UInt64(short[index]) : 0
            // Two limbs and a carry of one are far below the range of UInt64.
            let total = UInt64(long[index]) + addend + carry
            result.append(UInt32(truncatingIfNeeded: total))
            carry = total >> 32
        }
        if carry != 0 {
            result.append(UInt32(truncatingIfNeeded: carry))
        }
        return result
    }

    /// `lhs - rhs`, for an `lhs` that is not the smaller of the two. The
    /// callers compare first, because a magnitude cannot go below zero.
    static func difference(_ lhs: Limbs, _ rhs: Limbs) -> Limbs {
        var result = Limbs()
        result.reserveCapacity(lhs.count)
        var borrow: UInt32 = 0
        for index in lhs.indices {
            let subtrahend = index < rhs.count ? rhs[index] : 0
            let (partial, borrowedForLimb) = lhs[index].subtractingReportingOverflow(subtrahend)
            let (limb, borrowedForBorrow) = partial.subtractingReportingOverflow(borrow)
            result.append(limb)
            borrow = borrowedForLimb || borrowedForBorrow ? 1 : 0
        }
        return trimmed(result)
    }

    /// The schoolbook product: every limb of one operand times every limb of
    /// the other, added in at the place the two limbs share.
    static func product(_ lhs: Limbs, _ rhs: Limbs) -> Limbs {
        if lhs.isEmpty || rhs.isEmpty {
            return []
        }
        var result = Limbs(repeating: 0, count: lhs.count + rhs.count)
        for (offset, multiplier) in lhs.enumerated() where multiplier != 0 {
            var carry: UInt64 = 0
            for (index, multiplicand) in rhs.enumerated() {
                // The largest value here is (2^32 - 1)^2 + 2 * (2^32 - 1),
                // which is exactly 2^64 - 1.
                let total = UInt64(multiplier) * UInt64(multiplicand) + UInt64(result[offset + index]) + carry
                result[offset + index] = UInt32(truncatingIfNeeded: total)
                carry = total >> 32
            }
            result[offset + rhs.count] = UInt32(truncatingIfNeeded: carry)
        }
        return trimmed(result)
    }

    /// Replaces `limbs` with `limbs * factor + addend`. Reading digits is a
    /// run of these steps, so it works in place.
    static func multiply(_ limbs: inout Limbs, by factor: UInt32, adding addend: UInt32) {
        var carry = UInt64(addend)
        for index in limbs.indices {
            let total = UInt64(limbs[index]) * UInt64(factor) + carry
            limbs[index] = UInt32(truncatingIfNeeded: total)
            carry = total >> 32
        }
        if carry != 0 {
            limbs.append(UInt32(truncatingIfNeeded: carry))
        }
    }

    static func shiftedLeft(_ limbs: Limbs, by count: Int) -> Limbs {
        guard !limbs.isEmpty, count > 0 else { return limbs }
        let wholeLimbs = count / 32
        let bits = count % 32
        var result = Limbs(repeating: 0, count: wholeLimbs)
        result.reserveCapacity(wholeLimbs + limbs.count + 1)
        if bits == 0 {
            result.append(contentsOf: limbs)
            return result
        }
        var carry: UInt32 = 0
        for limb in limbs {
            result.append((limb << bits) | carry)
            carry = limb >> (32 - bits)
        }
        if carry != 0 {
            result.append(carry)
        }
        return result
    }

    /// `limbs >> count`, dropping the bits shifted out.
    static func shiftedRight(_ limbs: Limbs, by count: Int) -> Limbs {
        guard count > 0 else { return limbs }
        let wholeLimbs = count / 32
        guard wholeLimbs < limbs.count else { return [] }
        let bits = count % 32
        var result = Limbs(limbs[wholeLimbs...])
        if bits != 0 {
            for index in result.indices {
                let fromAbove = index + 1 < result.count ? result[index + 1] << (32 - bits) : 0
                result[index] = (result[index] >> bits) | fromAbove
            }
        }
        return trimmed(result)
    }

    /// Division by one limb, the short division of school arithmetic. A zero
    /// divisor gives zeros; the callers refuse it before they get here.
    static func quotientAndRemainder(
        _ dividend: Limbs, dividingBySmall divisor: UInt32
    ) -> (quotient: Limbs, remainder: UInt32) {
        guard divisor != 0 else { return ([], 0) }
        var quotient = Limbs(repeating: 0, count: dividend.count)
        var remainder: UInt64 = 0
        var index = dividend.count
        while index > 0 {
            index -= 1
            // The remainder is below the divisor, so this is below
            // divisor * 2^32 and the quotient digit fits in one limb.
            let partial = (remainder << 32) | UInt64(dividend[index])
            quotient[index] = UInt32(truncatingIfNeeded: partial / UInt64(divisor))
            remainder = partial % UInt64(divisor)
        }
        return (trimmed(quotient), UInt32(truncatingIfNeeded: remainder))
    }

    /// Long division, as in Knuth's Algorithm D: each quotient limb is
    /// guessed from the top limbs of what is left of the dividend and then
    /// corrected. A zero divisor gives zeros; the callers refuse it before
    /// they get here.
    static func quotientAndRemainder(
        _ dividend: Limbs, dividingBy divisor: Limbs
    ) -> (quotient: Limbs, remainder: Limbs) {
        guard let divisorTop = divisor.last, divisorTop != 0 else { return ([], []) }
        if compare(dividend, divisor) < 0 {
            return ([], dividend)
        }
        if divisor.count == 1 {
            let (quotient, remainder) = quotientAndRemainder(dividend, dividingBySmall: divisorTop)
            return (quotient, remainder == 0 ? [] : [remainder])
        }

        // Scaling both operands until the top bit of the divisor is set
        // leaves the quotient alone and makes a guess from the top limbs at
        // most two too large, which is what bounds the corrections below.
        let scale = divisorTop.leadingZeroBitCount
        let scaledDivisor = shiftedLeft(divisor, by: scale)
        var rest = shiftedLeft(dividend, by: scale)
        while rest.count <= dividend.count {
            rest.append(0)
        }
        let divisorCount = scaledDivisor.count
        let quotientCount = dividend.count - divisorCount + 1
        let top = UInt64(scaledDivisor[divisorCount - 1])
        let second = UInt64(scaledDivisor[divisorCount - 2])
        var quotient = Limbs(repeating: 0, count: quotientCount)

        var place = quotientCount
        while place > 0 {
            place -= 1
            // Guess the quotient limb from the top two limbs of the rest and
            // the top limb of the divisor, then lower the guess while the
            // divisor's second limb shows it to be too large. The rest stays
            // below the divisor times 2^32, so the guess is at most
            // 2^32 + 1 and the loop leaves it below 2^32.
            let leading = (UInt64(rest[place + divisorCount]) << 32) | UInt64(rest[place + divisorCount - 1])
            var guess = leading / top
            var guessRemainder = leading % top
            while guess > 0xFFFF_FFFF
                || guess * second > ((guessRemainder << 32) | UInt64(rest[place + divisorCount - 2]))
            {
                guess -= 1
                guessRemainder += top
                if guessRemainder > 0xFFFF_FFFF {
                    break
                }
            }
            var digit = UInt32(truncatingIfNeeded: guess)

            // Subtract digit * divisor from the rest at this place.
            var carry: UInt64 = 0
            var borrow: UInt32 = 0
            for index in 0..<divisorCount {
                let scaled = UInt64(digit) * UInt64(scaledDivisor[index]) + carry
                carry = scaled >> 32
                let (partial, borrowedForLimb) = rest[place + index]
                    .subtractingReportingOverflow(UInt32(truncatingIfNeeded: scaled))
                let (limb, borrowedForBorrow) = partial.subtractingReportingOverflow(borrow)
                rest[place + index] = limb
                borrow = borrowedForLimb || borrowedForBorrow ? 1 : 0
            }
            let (partial, borrowedForLimb) = rest[place + divisorCount]
                .subtractingReportingOverflow(UInt32(truncatingIfNeeded: carry))
            let (limb, borrowedForBorrow) = partial.subtractingReportingOverflow(borrow)
            rest[place + divisorCount] = limb

            if borrowedForLimb || borrowedForBorrow {
                // The guess was still one too large, which is rare: the
                // subtraction went below zero, so put one divisor back. The
                // carry out of this addition cancels the borrow, which is
                // why both are allowed to wrap.
                digit &-= 1
                var carryBack: UInt64 = 0
                for index in 0..<divisorCount {
                    let total = UInt64(rest[place + index]) + UInt64(scaledDivisor[index]) + carryBack
                    rest[place + index] = UInt32(truncatingIfNeeded: total)
                    carryBack = total >> 32
                }
                rest[place + divisorCount] = rest[place + divisorCount] &+ UInt32(truncatingIfNeeded: carryBack)
            }
            quotient[place] = digit
        }

        let remainder = shiftedRight(trimmed(Limbs(rest[0..<divisorCount])), by: scale)
        return (trimmed(quotient), remainder)
    }

    /// Euclid's algorithm. The greatest common divisor with zero is the
    /// other operand.
    static func greatestCommonDivisor(_ lhs: Limbs, _ rhs: Limbs) -> Limbs {
        var larger = lhs
        var smaller = rhs
        while !smaller.isEmpty {
            let remainder = quotientAndRemainder(larger, dividingBy: smaller).remainder
            larger = smaller
            smaller = remainder
        }
        return larger
    }

    /// Turns a value into its negation in two's complement, within the same
    /// number of limbs: every bit inverted, plus one.
    static func negatedInPlace(_ limbs: inout Limbs) {
        var carry = true
        for index in limbs.indices {
            let inverted = ~limbs[index]
            if carry {
                let (limb, overflowed) = inverted.addingReportingOverflow(1)
                limbs[index] = limb
                carry = overflowed
            } else {
                limbs[index] = inverted
            }
        }
    }
}

/// An integer of any size: sign and magnitude.
///
/// Zero is never negative and the magnitude has one form, so equal values
/// are stored alike and the synthesized equality and hashing are right.
struct GoBigInt: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The absolute value, in the form `Magnitude` describes.
    fileprivate let magnitude: [UInt32]

    /// Whether the value is below zero; false for zero.
    private let negative: Bool

    static let zero = GoBigInt(magnitude: [], isNegative: false)
    static let one = GoBigInt(magnitude: [1], isNegative: false)

    /// Every value is made here, so that the magnitude is always trimmed and
    /// zero never carries a sign.
    fileprivate init(magnitude: [UInt32], isNegative: Bool) {
        let trimmed = Magnitude.trimmed(magnitude)
        self.magnitude = trimmed
        self.negative = isNegative && !trimmed.isEmpty
    }

    init(_ value: Int64) {
        self.init(magnitude: Magnitude.limbs(of: value.magnitude), isNegative: value < 0)
    }

    init(_ value: UInt64) {
        self.init(magnitude: Magnitude.limbs(of: value), isNegative: false)
    }

    /// The digits of a magnitude in `radix` (2...16), upper or lower case,
    /// with nothing else in the text; nil for an empty text or a bad digit.
    /// A radix outside 2...16 also gives nil.
    init?(digits: Substring, radix: Int) {
        self.init(digitBytes: digits.utf8, radix: radix)
    }

    /// The same reading from bytes, which is the form the literal reader has
    /// its digits in once the underscores are gone.
    fileprivate init?<Bytes: Sequence>(digitBytes: Bytes, radix: Int) where Bytes.Element == UInt8 {
        guard (2...16).contains(radix) else { return nil }
        let base = UInt32(radix)
        // Folding one digit at a time into a long number costs a pass over
        // the whole number per digit. Digits are gathered into one limb
        // first, as many as fit, so a long mantissa costs a pass per group.
        let largestGroupScale = UInt32.max / base
        var limbs: [UInt32] = []
        var group: UInt32 = 0
        var groupScale: UInt32 = 1
        var sawDigit = false
        for byte in digitBytes {
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                digit = UInt32(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                digit = UInt32(byte - UInt8(ascii: "A")) + 10
            default:
                return nil
            }
            guard digit < base else { return nil }
            sawDigit = true
            if groupScale > largestGroupScale {
                Magnitude.multiply(&limbs, by: groupScale, adding: group)
                group = 0
                groupScale = 1
            }
            // The scale is at most UInt32.max / base here and the group is
            // below the scale, so neither product leaves a limb.
            group = group * base + digit
            groupScale *= base
        }
        guard sawDigit else { return nil }
        Magnitude.multiply(&limbs, by: groupScale, adding: group)
        self.init(magnitude: limbs, isNegative: false)
    }

    var isZero: Bool { magnitude.isEmpty }

    var isNegative: Bool { negative }

    /// -1, 0, or 1.
    var signum: Int {
        if magnitude.isEmpty {
            return 0
        }
        return negative ? -1 : 1
    }

    /// Bits in the magnitude; 0 for zero.
    var bitWidth: Int { Magnitude.bitWidth(magnitude) }

    /// The value when it fits, else nil.
    var int64: Int64? {
        guard magnitude.count <= 2 else { return nil }
        let bits = Magnitude.lowBits(magnitude)
        if negative {
            // The lowest Int64 is -2^63, whose magnitude is one more than
            // the highest; negating in two's complement covers it too.
            guard bits <= UInt64(1) << 63 else { return nil }
            return Int64(truncatingIfNeeded: 0 &- bits)
        }
        return Int64(exactly: bits)
    }

    /// The value when it fits, else nil.
    var uint64: UInt64? {
        guard !negative, magnitude.count <= 2 else { return nil }
        return Magnitude.lowBits(magnitude)
    }

    /// The low 64 bits of the two's complement form, whatever the size:
    /// what a conversion that wraps keeps. -1 gives all ones.
    var truncatedBits: UInt64 {
        let bits = Magnitude.lowBits(magnitude)
        // Negation and truncation to 64 bits can be done in either order.
        return negative ? 0 &- bits : bits
    }

    static func < (lhs: GoBigInt, rhs: GoBigInt) -> Bool {
        if lhs.negative != rhs.negative {
            return lhs.negative
        }
        let order = Magnitude.compare(lhs.magnitude, rhs.magnitude)
        return lhs.negative ? order > 0 : order < 0
    }

    static prefix func - (value: GoBigInt) -> GoBigInt {
        GoBigInt(magnitude: value.magnitude, isNegative: !value.negative)
    }

    static func + (lhs: GoBigInt, rhs: GoBigInt) -> GoBigInt {
        if lhs.negative == rhs.negative {
            return GoBigInt(magnitude: Magnitude.sum(lhs.magnitude, rhs.magnitude), isNegative: lhs.negative)
        }
        // With opposite signs the magnitudes subtract, the smaller from the
        // larger, and the larger one gives the sign.
        if Magnitude.compare(lhs.magnitude, rhs.magnitude) >= 0 {
            return GoBigInt(magnitude: Magnitude.difference(lhs.magnitude, rhs.magnitude), isNegative: lhs.negative)
        }
        return GoBigInt(magnitude: Magnitude.difference(rhs.magnitude, lhs.magnitude), isNegative: rhs.negative)
    }

    static func - (lhs: GoBigInt, rhs: GoBigInt) -> GoBigInt {
        lhs + (-rhs)
    }

    static func * (lhs: GoBigInt, rhs: GoBigInt) -> GoBigInt {
        GoBigInt(
            magnitude: Magnitude.product(lhs.magnitude, rhs.magnitude),
            isNegative: lhs.negative != rhs.negative
        )
    }

    /// Go's `/` and `%` on integers: the quotient truncated toward zero and
    /// the remainder with the sign of the dividend; nil for a zero divisor.
    func quotientAndRemainder(dividingBy divisor: GoBigInt) -> (quotient: GoBigInt, remainder: GoBigInt)? {
        guard !divisor.isZero else { return nil }
        // Dividing the magnitudes truncates toward zero, which is Go's rule,
        // so only the signs are left to settle.
        let (quotient, remainder) = Magnitude.quotientAndRemainder(magnitude, dividingBy: divisor.magnitude)
        return (
            GoBigInt(magnitude: quotient, isNegative: negative != divisor.negative),
            GoBigInt(magnitude: remainder, isNegative: negative)
        )
    }

    /// `self << count`; `count` is not negative (a negative count gives self).
    ///
    /// The result has `count` more bits than the value, so the caller keeps
    /// the count within reason, as Go does: it refuses a constant shift of
    /// more than 1074 bits.
    func shiftedLeft(_ count: Int) -> GoBigInt {
        guard count > 0 else { return self }
        return GoBigInt(magnitude: Magnitude.shiftedLeft(magnitude, by: count), isNegative: negative)
    }

    /// `self >> count` as Go's constants shift: toward negative infinity,
    /// so -1 >> 1 is -1. A negative count gives self.
    func shiftedRight(_ count: Int) -> GoBigInt {
        guard count > 0 else { return self }
        if !negative {
            return GoBigInt(magnitude: Magnitude.shiftedRight(magnitude, by: count), isNegative: false)
        }
        // Shifting the magnitude would round toward zero. For a negative
        // value -m, rounding down gives -(((m - 1) >> count) + 1).
        let lowered = Magnitude.difference(magnitude, [1])
        let shifted = Magnitude.shiftedRight(lowered, by: count)
        return GoBigInt(magnitude: Magnitude.sum(shifted, [1]), isNegative: true)
    }

    /// The two's complement form in `limbCount` limbs, which the caller
    /// makes at least one more than the magnitude has, so that the top limb
    /// is all sign.
    private func twosComplement(limbCount: Int) -> [UInt32] {
        var limbs = magnitude
        while limbs.count < limbCount {
            limbs.append(0)
        }
        if negative {
            Magnitude.negatedInPlace(&limbs)
        }
        return limbs
    }

    /// The value of a two's complement form whose top bit is its sign.
    private init(twosComplement limbs: [UInt32]) {
        let isNegative = (limbs.last ?? 0) >> 31 == 1
        var magnitude = limbs
        if isNegative {
            Magnitude.negatedInPlace(&magnitude)
        }
        self.init(magnitude: magnitude, isNegative: isNegative)
    }

    /// Applies a bitwise operator limb by limb. Go's constants behave as
    /// two's complement numbers whose sign bit repeats without end; one limb
    /// beyond the longer operand holds that repeating sign for both, and
    /// every limb above it would only repeat the result's top limb.
    private static func bitwise(
        _ lhs: GoBigInt, _ rhs: GoBigInt, _ combine: (UInt32, UInt32) -> UInt32
    ) -> GoBigInt {
        let limbCount = max(lhs.magnitude.count, rhs.magnitude.count) + 1
        let left = lhs.twosComplement(limbCount: limbCount)
        let right = rhs.twosComplement(limbCount: limbCount)
        var result: [UInt32] = []
        result.reserveCapacity(limbCount)
        for (leftLimb, rightLimb) in zip(left, right) {
            result.append(combine(leftLimb, rightLimb))
        }
        return GoBigInt(twosComplement: result)
    }

    /// Bitwise operators on the two's complement form with the sign
    /// extended without end, as Go's constants have them (`math/big`'s
    /// And, Or, Xor, AndNot, Not).
    static func & (lhs: GoBigInt, rhs: GoBigInt) -> GoBigInt {
        bitwise(lhs, rhs) { $0 & $1 }
    }

    static func | (lhs: GoBigInt, rhs: GoBigInt) -> GoBigInt {
        bitwise(lhs, rhs) { $0 | $1 }
    }

    static func ^ (lhs: GoBigInt, rhs: GoBigInt) -> GoBigInt {
        bitwise(lhs, rhs) { $0 ^ $1 }
    }

    /// Go's `&^`: the bits of `self` that are not set in `other`.
    func andNot(_ other: GoBigInt) -> GoBigInt {
        GoBigInt.bitwise(self, other) { $0 & ~$1 }
    }

    /// Inverting every bit of a two's complement number gives -x - 1.
    static prefix func ~ (value: GoBigInt) -> GoBigInt {
        -value - .one
    }

    /// Decimal.
    var description: String {
        if magnitude.isEmpty {
            return "0"
        }
        // Dividing by 10^9 again and again peels off nine digits at a time,
        // the most that one limb holds.
        var groups: [UInt32] = []
        var rest = magnitude
        while !rest.isEmpty {
            let (quotient, remainder) = Magnitude.quotientAndRemainder(rest, dividingBySmall: 1_000_000_000)
            groups.append(remainder)
            rest = quotient
        }
        var text = negative ? "-" : ""
        for (position, group) in groups.reversed().enumerated() {
            let digits = String(group)
            if position > 0 {
                // Every group but the first stands for exactly nine digits.
                text += String(repeating: "0", count: max(0, 9 - digits.count))
            }
            text += digits
        }
        return text
    }
}

/// An exact fraction in lowest terms with a positive denominator.
///
/// Keeping every value in lowest terms gives each one a single form, so the
/// synthesized equality and hashing are right, and it keeps the numbers from
/// growing through a chain of operations.
struct GoRational: Hashable, Comparable, Sendable {
    let numerator: GoBigInt
    let denominator: GoBigInt

    init(_ integer: GoBigInt) {
        self.numerator = integer
        self.denominator = .one
    }

    /// nil for a zero denominator.
    init?(numerator: GoBigInt, denominator: GoBigInt) {
        guard !denominator.isZero else { return nil }
        self.init(reducing: numerator, over: denominator)
    }

    /// The lowest terms of a fraction whose denominator is known not to be
    /// zero, which holds for the products of denominators that the operators
    /// pass here.
    private init(reducing numerator: GoBigInt, over denominator: GoBigInt) {
        let common = Magnitude.greatestCommonDivisor(numerator.magnitude, denominator.magnitude)
        let top = Magnitude.quotientAndRemainder(numerator.magnitude, dividingBy: common).quotient
        let bottom = Magnitude.quotientAndRemainder(denominator.magnitude, dividingBy: common).quotient
        // The sign moves to the numerator so that the denominator is
        // positive.
        self.numerator = GoBigInt(magnitude: top, isNegative: numerator.isNegative != denominator.isNegative)
        self.denominator = GoBigInt(magnitude: bottom, isNegative: false)
    }

    /// A fraction already in lowest terms with a positive denominator.
    private init(lowestTermsNumerator numerator: GoBigInt, denominator: GoBigInt) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// The exact value of a finite Double; nil for NaN and the infinities.
    /// Negative zero is zero.
    init?(exactly value: Double) {
        guard value.isFinite else { return nil }
        let bits = value.bitPattern
        let hiddenBit = UInt64(1) << 52
        let fraction = bits & (hiddenBit - 1)
        let storedExponent = Int((bits >> 52) & 0x7FF)
        // A normal number has a leading one that is not stored. A subnormal
        // has none and shares the exponent of the smallest normal number.
        let significand = storedExponent == 0 ? fraction : fraction | hiddenBit
        let exponent = max(storedExponent, 1) - 1075
        let magnitude = GoBigInt(significand)
        let signed = value.sign == .minus ? -magnitude : magnitude
        if exponent >= 0 {
            self.init(signed.shiftedLeft(exponent))
        } else {
            self.init(reducing: signed, over: GoBigInt.one.shiftedLeft(-exponent))
        }
    }

    var isInteger: Bool { denominator == .one }

    var signum: Int { numerator.signum }

    /// The integer part, truncated toward zero.
    var truncated: GoBigInt {
        // The denominator is never zero, so the division always has a result.
        numerator.quotientAndRemainder(dividingBy: denominator)?.quotient ?? .zero
    }

    /// With positive denominators, cross multiplying keeps the order.
    static func < (lhs: GoRational, rhs: GoRational) -> Bool {
        lhs.numerator * rhs.denominator < rhs.numerator * lhs.denominator
    }

    static prefix func - (value: GoRational) -> GoRational {
        GoRational(lowestTermsNumerator: -value.numerator, denominator: value.denominator)
    }

    static func + (lhs: GoRational, rhs: GoRational) -> GoRational {
        GoRational(
            reducing: lhs.numerator * rhs.denominator + rhs.numerator * lhs.denominator,
            over: lhs.denominator * rhs.denominator
        )
    }

    static func - (lhs: GoRational, rhs: GoRational) -> GoRational {
        lhs + (-rhs)
    }

    static func * (lhs: GoRational, rhs: GoRational) -> GoRational {
        GoRational(reducing: lhs.numerator * rhs.numerator, over: lhs.denominator * rhs.denominator)
    }

    /// nil for a zero divisor.
    func divided(by divisor: GoRational) -> GoRational? {
        GoRational(numerator: numerator * divisor.denominator, denominator: denominator * divisor.numerator)
    }

    /// The nearest float64, ties to even, as IEEE 754 rounds and as Go
    /// rounds a constant converted to float64 (`big.Rat.Float64`); plus or
    /// minus infinity when the magnitude is too large, and zero (positive)
    /// when it rounds to zero. Subnormal results are rounded correctly.
    var nearestDouble: Double {
        Double(bitPattern: nearestBits(precision: 53, exponentBits: 11))
    }

    /// The nearest float32 (`big.Rat.Float32`), held in a Double, with the
    /// same rules; rounded once, from the exact value, not through float64.
    ///
    /// Rounding to float64 first could land exactly halfway between two
    /// float32 values and then break the tie the wrong way.
    var nearestSingle: Double {
        let bits = nearestBits(precision: 24, exponentBits: 8)
        return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
    }

    /// The bit pattern of the nearest value in an IEEE 754 binary format
    /// whose significand has `precision` bits, the hidden one included.
    ///
    /// The value is divided by the weight of the last bit that the result
    /// can hold, which leaves an integer significand and a remainder, and
    /// the remainder says which way to round. That is one exact rounding,
    /// whatever the sizes of the numerator and the denominator.
    private func nearestBits(precision: Int, exponentBits: Int) -> UInt64 {
        if numerator.isZero {
            return 0
        }
        let fractionBits = precision - 1
        let bias = (1 << (exponentBits - 1)) - 1
        let highestExponent = bias
        let lowestExponent = 1 - bias
        let sign: UInt64 = numerator.isNegative ? 1 << (fractionBits + exponentBits) : 0
        let infinity = UInt64((1 << exponentBits) - 1) << fractionBits
        let top = numerator.magnitude
        let bottom = denominator.magnitude

        // Find the exponent with 2^exponent <= value < 2^(exponent + 1). The
        // bit widths give it to within one, and a comparison settles it.
        var exponent = Magnitude.bitWidth(top) - Magnitude.bitWidth(bottom)
        let aligned =
            exponent >= 0
            ? Magnitude.compare(top, Magnitude.shiftedLeft(bottom, by: exponent))
            : Magnitude.compare(Magnitude.shiftedLeft(top, by: -exponent), bottom)
        if aligned < 0 {
            exponent -= 1
        }

        // These two answers need no division, and returning them here keeps
        // a huge or tiny constant from being shifted across its whole length.
        // Anything below half of the smallest subnormal rounds to zero.
        if exponent > highestExponent {
            return sign | infinity
        }
        if exponent < lowestExponent - precision {
            return 0
        }

        // The last bit of a normal result weighs 2^(exponent - fractionBits).
        // Below the normal range the weight stops shrinking, which is what
        // makes subnormal results come out with fewer bits.
        var resultExponent = max(exponent, lowestExponent)
        let weight = resultExponent - fractionBits
        let dividend = weight < 0 ? Magnitude.shiftedLeft(top, by: -weight) : top
        let divisor = weight > 0 ? Magnitude.shiftedLeft(bottom, by: weight) : bottom
        let (quotient, remainder) = Magnitude.quotientAndRemainder(dividend, dividingBy: divisor)
        var significand = Magnitude.lowBits(quotient)

        // Round to nearest by comparing twice the remainder with the divisor;
        // exactly halfway goes to the even significand.
        let half = Magnitude.compare(Magnitude.shiftedLeft(remainder, by: 1), divisor)
        if half > 0 || (half == 0 && significand % 2 == 1) {
            significand += 1
        }
        if significand == (UInt64(1) << precision) {
            // Rounding carried into a new top bit: the same value is half
            // the significand at the next exponent.
            significand >>= 1
            resultExponent += 1
        }

        if significand < (UInt64(1) << fractionBits) {
            // Subnormal or zero: the stored exponent is zero, and a zero
            // result is positive whatever the sign of the value.
            return significand == 0 ? 0 : sign | significand
        }
        if resultExponent > highestExponent {
            return sign | infinity
        }
        let storedExponent = UInt64(resultExponent + bias)
        let storedFraction = significand & ((UInt64(1) << fractionBits) - 1)
        return sign | (storedExponent << fractionBits) | storedFraction
    }
}

enum GoNumberLiteral {
    /// Decimal or binary exponents beyond this are refused, so that no
    /// literal makes the compiler build a number of millions of digits.
    static let maximumExponent = 100_000

    /// The exact value of a Go numeric literal as the source spells it, and
    /// whether it is a floating-point literal (it has a `.`, a decimal
    /// exponent, or a hexadecimal `p` exponent): `42`, `0x1f`, `0o17`,
    /// `017`, `0b101`, `1_000`, `1.5`, `.5`, `1.`, `1e9`, `1E-3`,
    /// `1_000.5`, `0x1p-2`, `0X1.8P+3`, `0x_1F`, `0x.8p1`, `08.5`, `09e1`.
    /// The spelling was already accepted by a lexer that enforces Go's
    /// rules, so this need not diagnose; it returns nil for text it cannot
    /// read and for an exponent whose magnitude is over `maximumExponent`.
    ///
    /// A literal whose mantissa is zero is zero whatever its exponent, as it
    /// is in Go, because nothing large has to be built for it. The one
    /// exception is also Go's: an exponent that does not fit in 64 bits
    /// makes any literal malformed, and this returns nil for it.
    static func value(of spelling: String) -> (value: GoRational, isFloat: Bool)? {
        // Underscores only separate digits and never change the value. The
        // lexer has checked where they stand, so they can simply go.
        let text = spelling.utf8.filter { $0 != UInt8(ascii: "_") }

        var radix = 10
        var position = 0
        if text.count >= 2, text[0] == UInt8(ascii: "0") {
            switch text[1] {
            case UInt8(ascii: "x"), UInt8(ascii: "X"):
                radix = 16
            case UInt8(ascii: "o"), UInt8(ascii: "O"):
                radix = 8
            case UInt8(ascii: "b"), UInt8(ascii: "B"):
                radix = 2
            default:
                break
            }
            if radix != 10 {
                position = 2
            }
        }
        let hasPrefix = position > 0

        // A decimal mantissa ends at `e` and a hexadecimal one at `p`. In a
        // hexadecimal mantissa `e` is a digit, and binary and octal literals
        // have no exponent, so there any letter is left to fail as a digit.
        let lowerMarker: UInt8? = radix == 10 ? UInt8(ascii: "e") : radix == 16 ? UInt8(ascii: "p") : nil
        let upperMarker: UInt8? = radix == 10 ? UInt8(ascii: "E") : radix == 16 ? UInt8(ascii: "P") : nil
        var wholeDigits: [UInt8] = []
        var fractionDigits: [UInt8] = []
        var hasPoint = false
        while position < text.count {
            let byte = text[position]
            if byte == lowerMarker || byte == upperMarker {
                break
            }
            position += 1
            if byte == UInt8(ascii: ".") {
                if hasPoint {
                    return nil
                }
                hasPoint = true
            } else if hasPoint {
                fractionDigits.append(byte)
            } else {
                wholeDigits.append(byte)
            }
        }

        // The exponent is always written in decimal, whatever the radix of
        // the mantissa. Go reads it into 64 bits before it looks at anything
        // else and calls the literal malformed when it does not fit, even
        // when the mantissa is zero, so that comes first here too.
        var hasExponent = false
        var exponentIsNegative = false
        var exponentMagnitude: UInt64 = 0
        if position < text.count {
            hasExponent = true
            position += 1
            if position < text.count, text[position] == UInt8(ascii: "+") || text[position] == UInt8(ascii: "-") {
                exponentIsNegative = text[position] == UInt8(ascii: "-")
                position += 1
            }
            guard position < text.count else { return nil }
            while position < text.count {
                let byte = text[position]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                position += 1
                let (scaled, scalingOverflowed) = exponentMagnitude.multipliedReportingOverflow(by: 10)
                let (next, addingOverflowed) = scaled.addingReportingOverflow(UInt64(byte - UInt8(ascii: "0")))
                guard !scalingOverflowed, !addingOverflowed else { return nil }
                exponentMagnitude = next
            }
            // The lowest Int64 has a magnitude one above the highest.
            let largestReadable = exponentIsNegative ? UInt64(1) << 63 : (UInt64(1) << 63) - 1
            guard exponentMagnitude <= largestReadable else { return nil }
        }

        guard !wholeDigits.isEmpty || !fractionDigits.isEmpty else { return nil }

        if !hasPoint && !hasExponent {
            // An integer without a prefix that starts with a zero is in the
            // old octal form: 017 is fifteen.
            let isLegacyOctal = !hasPrefix && wholeDigits.count > 1 && wholeDigits[0] == UInt8(ascii: "0")
            guard let integer = GoBigInt(digitBytes: wholeDigits, radix: isLegacyOctal ? 8 : radix) else {
                return nil
            }
            return (GoRational(integer), false)
        }

        // Only decimal and hexadecimal literals can be floating-point, and
        // Go requires the `p` exponent on a hexadecimal one.
        guard radix == 10 || (radix == 16 && hasExponent) else { return nil }
        // The mantissa is read as one integer, the point left out; each
        // digit after the point is then undone by one step of the scale.
        // A leading zero does not make a floating-point literal octal.
        guard let mantissa = GoBigInt(digitBytes: wholeDigits + fractionDigits, radix: radix) else {
            return nil
        }
        if mantissa.isZero {
            return (GoRational(.zero), true)
        }
        guard let magnitude = Int(exactly: exponentMagnitude), magnitude <= maximumExponent else { return nil }
        let exponent = exponentIsNegative ? -magnitude : magnitude

        // A decimal exponent counts powers of ten and a `p` exponent powers
        // of two, and a hexadecimal digit after the point is four of those.
        let scale = radix == 10 ? exponent - fractionDigits.count : exponent - 4 * fractionDigits.count
        let size = scale < 0 ? -scale : scale
        let factor = radix == 10 ? powerOfTen(size) : GoBigInt.one.shiftedLeft(size)
        if scale >= 0 {
            return (GoRational(mantissa * factor), true)
        }
        guard let value = GoRational(numerator: mantissa, denominator: factor) else { return nil }
        return (value, true)
    }

    /// Ten to a power that is not negative, by repeated squaring, so that
    /// the largest exponent allowed costs a few dozen multiplications.
    private static func powerOfTen(_ exponent: Int) -> GoBigInt {
        var result = GoBigInt.one
        var square = GoBigInt(UInt64(10))
        var remaining = exponent
        while remaining > 0 {
            if remaining % 2 == 1 {
                result = result * square
            }
            remaining /= 2
            if remaining > 0 {
                square = square * square
            }
        }
        return result
    }
}
