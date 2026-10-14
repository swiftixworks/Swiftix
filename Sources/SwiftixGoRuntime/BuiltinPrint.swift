/// What Go's runtime writes for the operands of `print` and `println`
/// (`printint`, `printuint`, `printfloat`, `printbool`, `printstring`,
/// `printpointer` of runtime/print.go). Pure functions of the values and
/// their types.
enum GoRuntimePrint {
    /// The text of one operand of type `type`.
    static func text(of value: GoValue, type: GoRuntimeType?, underlying: (GoRuntimeType) -> GoRuntimeType)
        -> String
    {
        let shape = type.map(underlying)
        switch (shape, value) {
        case (.number(let kind)?, .int(let bits)):
            switch kind {
            case .float32, .float64: return float(Double(bitPattern: UInt64(bitPattern: bits)))
            case .uint, .uint16, .uint32, .uint64, .uintptr: return String(UInt64(bitPattern: bits))
            default: return String(bits)
            }
        case (.byte?, .int(let bits)): return String(UInt8(truncatingIfNeeded: bits))
        case (_, .int(let bits)): return String(bits)
        case (_, .string(let text)): return text
        case (_, .bool(let flag)): return flag ? "true" : "false"
        case (.interface?, _), (.error?, _):
            return value == .nilValue ? "(0x0,0x0)" : "(0xc000012000,0xc000014000)"
        case (.slice?, .nilValue): return "[0/0]0x0"
        case (.slice?, .slice(let slice)): return "[\(slice.length)/\(slice.capacity)]0xc000016000"
        default:
            return value == .nilValue ? "0x0" : "0xc000010000"
        }
    }

    /// Go's `printfloat`: seven digits and an exponent, `+1.500000e+000`.
    static func float(_ input: Double) -> String {
        var v = input
        if v != v { return "NaN" }
        if v + v == v, v > 0 { return "+Inf" }
        if v + v == v, v < 0 { return "-Inf" }
        let n = 7  // digits printed
        var buf = [UInt8](repeating: 0, count: n + 7)
        buf[0] = UInt8(ascii: "+")
        var e = 0  // exp
        if v == 0 {
            if 1 / v < 0 { buf[0] = UInt8(ascii: "-") }
        } else {
            if v < 0 {
                v = -v
                buf[0] = UInt8(ascii: "-")
            }
            // normalize
            while v >= 10 {
                e += 1
                v /= 10
            }
            while v < 1 {
                e -= 1
                v *= 10
            }
            // round
            var h = 5.0
            for _ in 0..<n { h /= 10 }
            v += h
            if v >= 10 {
                e += 1
                v /= 10
            }
        }
        // format +d.dddd+edd
        for i in 0..<n {
            let s = Int(v)
            buf[i + 2] = UInt8(s + 48)
            v -= Double(s)
            v *= 10
        }
        buf[1] = buf[2]
        buf[2] = UInt8(ascii: ".")
        buf[n + 2] = UInt8(ascii: "e")
        buf[n + 3] = UInt8(ascii: "+")
        if e < 0 {
            e = -e
            buf[n + 3] = UInt8(ascii: "-")
        }
        buf[n + 4] = UInt8(e / 100 + 48)
        buf[n + 5] = UInt8((e / 10) % 10 + 48)
        buf[n + 6] = UInt8(e % 10 + 48)
        return String(decoding: buf, as: UTF8.self)
    }
}
