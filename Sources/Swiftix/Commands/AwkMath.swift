/// Elementary transcendental functions for `awk` (`exp`, `log`, `sin`, `cos`,
/// `atan2`, and the `^` power operator), implemented on the standard library
/// alone because the core may not import Foundation or a platform libm.
///
/// Each function reduces its argument to a small interval and sums a short
/// Taylor / atanh series there; results agree with a C library to roughly
/// 1e-15 relative for ordinary arguments. Two documented limits: `sin` / `cos`
/// lose accuracy for |x| beyond about 1e9 (Cody–Waite reduction, not a full
/// multi-word π), and a non-integer power is computed as `exp(y·log x)`, whose
/// relative error grows with |y·log x|.
///
/// Concurrency: a caseless enum of pure functions; no state, no locks.
enum AwkMath {

    static let pi = 3.141592653589793
    private static let halfPi = 1.5707963267948966
    private static let ln2High = 6.93147180369123816490e-01
    private static let ln2Low = 1.90821492927058770002e-10
    private static let inverseLn2 = 1.44269504088896338700e+00

    /// e^x.
    static func exp(_ x: Double) -> Double {
        if x.isNaN { return x }
        if x > 709.782712893384 { return .infinity }
        if x < -745.14 { return 0 }
        let k = (x * inverseLn2).rounded()
        let r = (x - k * ln2High) - k * ln2Low
        // |r| <= ln2/2: Horner form of the Taylor series.
        var sum = 1.0
        var n = 22.0
        while n >= 1 {
            sum = 1 + r / n * sum
            n -= 1
        }
        return scale(sum, by: Int(k))
    }

    /// `value × 2^power`, stepping so an intermediate never overflows early.
    private static func scale(_ value: Double, by power: Int) -> Double {
        var result = value
        var remaining = power
        while remaining > 1000 {
            result *= 0x1p1000
            remaining -= 1000
        }
        while remaining < -1000 {
            result *= 0x1p-1000
            remaining += 1000
        }
        return result * Double(sign: .plus, exponent: remaining, significand: 1)
    }

    /// Natural logarithm. Negative input is NaN; zero is -infinity.
    static func log(_ x: Double) -> Double {
        if x.isNaN || x < 0 { return .nan }
        if x == 0 { return -.infinity }
        if x.isInfinite { return x }
        var exponent = Int(x.exponent)
        var mantissa = x.significand            // [1, 2)
        if mantissa > 1.4142135623730951 {
            mantissa /= 2
            exponent += 1
        }
        // log(m) = 2·atanh(s) with s = (m-1)/(m+1), |s| < 0.1716.
        let s = (mantissa - 1) / (mantissa + 1)
        let s2 = s * s
        var sum = 0.0
        var k = 31.0
        while k >= 1 {
            sum = sum * s2 + 1 / k
            k -= 2
        }
        let e = Double(exponent)
        return e * ln2High + (2 * s * sum + e * ln2Low)
    }

    /// Reduce `x` to `r` in [-π/4, π/4] plus the quadrant count mod 4.
    private static func reduceQuadrant(_ x: Double) -> (r: Double, quadrant: Int) {
        let k = (x * 6.36619772367581382433e-01).rounded()   // 2/π
        var r = x - k * 1.57079632673412561417e+00
        r -= k * 6.07710050630396597660e-11
        r -= k * 2.02226624871116645580e-21
        r -= k * 8.47842766036889956997e-32
        let quadrant = Int(k.truncatingRemainder(dividingBy: 4))
        return (r, (quadrant + 4) % 4)
    }

    private static func sinKernel(_ r: Double) -> Double {
        let r2 = r * r
        var sum = 1.0
        var n = 12.0
        while n >= 1 {
            sum = 1 - r2 / ((2 * n) * (2 * n + 1)) * sum
            n -= 1
        }
        return r * sum
    }

    private static func cosKernel(_ r: Double) -> Double {
        let r2 = r * r
        var sum = 1.0
        var n = 12.0
        while n >= 1 {
            sum = 1 - r2 / ((2 * n - 1) * (2 * n)) * sum
            n -= 1
        }
        return sum
    }

    static func sin(_ x: Double) -> Double {
        if x.isNaN || x.isInfinite { return .nan }
        if x.magnitude < 0.7853981633974483 { return sinKernel(x) }
        let (r, quadrant) = reduceQuadrant(x)
        switch quadrant {
        case 0: return sinKernel(r)
        case 1: return cosKernel(r)
        case 2: return -sinKernel(r)
        default: return -cosKernel(r)
        }
    }

    static func cos(_ x: Double) -> Double {
        if x.isNaN || x.isInfinite { return .nan }
        if x.magnitude < 0.7853981633974483 { return cosKernel(x) }
        let (r, quadrant) = reduceQuadrant(x)
        switch quadrant {
        case 0: return cosKernel(r)
        case 1: return -sinKernel(r)
        case 2: return -cosKernel(r)
        default: return sinKernel(r)
        }
    }

    /// atan on [0, 1], folding the upper part down with the π/6 identity.
    private static func atanUnit(_ a: Double) -> Double {
        let sqrt3 = 1.7320508075688772
        var x = a
        var offset = 0.0
        if a > 0.2679491924311227 {             // tan(π/12)
            x = (sqrt3 * a - 1) / (sqrt3 + a)
            offset = 0.5235987755982989         // π/6
        }
        let x2 = x * x
        var sum = 0.0
        var k = 39.0
        while k >= 1 {
            sum = 1 / k - x2 * sum
            k -= 2
        }
        return offset + x * sum
    }

    static func atan(_ x: Double) -> Double {
        if x.isNaN { return x }
        let a = x.magnitude
        let result = a > 1 ? halfPi - atanUnit(1 / a) : atanUnit(a)
        return x.sign == .minus ? -result : result
    }

    static func atan2(_ y: Double, _ x: Double) -> Double {
        if x.isNaN || y.isNaN { return .nan }
        if x == 0 {
            if y == 0 {
                let zero = x.sign == .minus ? pi : 0.0
                return y.sign == .minus ? -zero : zero
            }
            return y > 0 ? halfPi : -halfPi
        }
        if x.isInfinite && y.isInfinite {
            let quarter = x > 0 ? pi / 4 : 3 * pi / 4
            return y > 0 ? quarter : -quarter
        }
        let base = atan(y / x)
        if x > 0 { return base }
        return y.sign == .minus ? base - pi : base + pi
    }

    /// x^y. Integer exponents use exact repeated squaring; everything else
    /// goes through `exp(y·log x)`.
    static func pow(_ x: Double, _ y: Double) -> Double {
        if y == 0 { return 1 }
        if x.isNaN || y.isNaN { return .nan }
        if y == y.rounded(.towardZero), y.magnitude <= 1_048_576 {
            var exponent = Int(y.magnitude)
            var base = x
            var result = 1.0
            while exponent > 0 {
                if exponent & 1 == 1 { result *= base }
                base *= base
                exponent >>= 1
            }
            return y < 0 ? 1 / result : result
        }
        if x == 0 { return y > 0 ? 0 : .infinity }
        if x < 0 {
            // A huge (hence even-or-integral) exponent of a negative base.
            guard y == y.rounded(.towardZero) else { return .nan }
            let magnitude = exp(y * log(-x))
            return y.truncatingRemainder(dividingBy: 2) == 0 ? magnitude : -magnitude
        }
        return exp(y * log(x))
    }
}
