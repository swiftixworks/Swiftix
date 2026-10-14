/// The text of `encoding/json`: Go's scanner, which says where a value ends
/// and words every syntax error, and what is built on it alone (`Valid`,
/// `Compact`, `Indent`, the end of a value in a stream), with the escaping
/// of strings and the base64 of a `[]byte`. Each is a port of the Go 1.24.5
/// source, so that the errors and their offsets are Go's by construction.
/// Pure value types; no executor state.

/// Go's `scanner`: a state machine fed one byte at a time.
struct GoJSONScanner {
    /// What a byte was: `scanContinue` and the others of Go.
    enum Op: Int, Comparable {
        case `continue`, beginLiteral, beginObject, objectKey, objectValue, endObject
        case beginArray, arrayValue, endArray, skipSpace, end, error

        static func < (lhs: Op, rhs: Op) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The state functions of Go's scanner, by name.
    enum State {
        case beginValue, beginValueOrEmpty, beginStringOrEmpty, beginString, endValue, endTop
        case inString, inStringEsc, inStringEscU, inStringEscU1, inStringEscU12, inStringEscU123
        case neg, one, zero, dot, dot0, e, eSign, e0
        case t, tr, tru, f, fa, fal, fals, n, nu, nul, error
    }

    enum Parse { case objectKey, objectValue, arrayValue }

    /// Go's `maxNestingDepth`.
    static let maximumDepth = 10_000

    var step = State.beginValue
    var endTop = false
    var parseState: [Parse] = []
    /// The error, as Go's `SyntaxError`: its message and offset.
    var error: (message: String, offset: Int64)?
    /// Bytes consumed so far, which the caller counts as Go's callers do.
    var bytes: Int64 = 0

    mutating func reset() {
        step = .beginValue
        parseState.removeAll(keepingCapacity: true)
        error = nil
        endTop = false
    }

    /// Go's `eof`: whether the input may end here.
    mutating func eof() -> Op {
        if error != nil { return .error }
        if endTop { return .end }
        _ = feed(0x20)
        if endTop { return .end }
        if error == nil { error = ("unexpected end of JSON input", bytes) }
        return .error
    }

    static func isSpace(_ c: UInt8) -> Bool {
        c <= 0x20 && (c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A)
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isHex(_ c: UInt8) -> Bool {
        isDigit(c) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
    }

    private mutating func push(_ c: UInt8, _ state: Parse, _ success: Op) -> Op {
        parseState.append(state)
        if parseState.count <= Self.maximumDepth { return success }
        return fail(c, "exceeded max depth")
    }

    private mutating func pop() {
        parseState.removeLast()
        if parseState.isEmpty {
            step = .endTop
            endTop = true
        } else {
            step = .endValue
        }
    }

    mutating func fail(_ c: UInt8, _ context: String) -> Op {
        step = .error
        error = ("invalid character " + Self.quoteChar(c) + " " + context, bytes)
        return .error
    }

    /// Go's `quoteChar`: a byte in single quotes, escaped as `strconv.Quote`
    /// escapes the rune of its value.
    static func quoteChar(_ c: UInt8) -> String {
        if c == UInt8(ascii: "'") { return #"'\''"# }
        if c == UInt8(ascii: "\"") { return #"'"'"# }
        let quoted = GoFormat.quote(String(Character(Unicode.Scalar(c))), asciiOnly: false)
        return "'" + quoted.dropFirst().dropLast() + "'"
    }

    /// One byte: what Go's `scan.step(scan, c)` returns.
    mutating func feed(_ c: UInt8) -> Op {
        switch step {
        case .beginValueOrEmpty:
            if Self.isSpace(c) { return .skipSpace }
            if c == UInt8(ascii: "]") { return endValue(c) }
            return beginValue(c)
        case .beginValue:
            return beginValue(c)
        case .beginStringOrEmpty:
            if Self.isSpace(c) { return .skipSpace }
            if c == UInt8(ascii: "}") {
                parseState[parseState.count - 1] = .objectValue
                return endValue(c)
            }
            return beginString(c)
        case .beginString:
            return beginString(c)
        case .endValue:
            return endValue(c)
        case .endTop:
            return endTopState(c)
        case .inString:
            if c == UInt8(ascii: "\"") {
                step = .endValue
                return .continue
            }
            if c == UInt8(ascii: "\\") {
                step = .inStringEsc
                return .continue
            }
            if c < 0x20 { return fail(c, "in string literal") }
            return .continue
        case .inStringEsc:
            switch c {
            case UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"),
                UInt8(ascii: "t"), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "\""):
                step = .inString
                return .continue
            case UInt8(ascii: "u"):
                step = .inStringEscU
                return .continue
            default:
                return fail(c, "in string escape code")
            }
        case .inStringEscU, .inStringEscU1, .inStringEscU12, .inStringEscU123:
            guard Self.isHex(c) else { return fail(c, "in \\u hexadecimal character escape") }
            switch step {
            case .inStringEscU: step = .inStringEscU1
            case .inStringEscU1: step = .inStringEscU12
            case .inStringEscU12: step = .inStringEscU123
            default: step = .inString
            }
            return .continue
        case .neg:
            if c == UInt8(ascii: "0") {
                step = .zero
                return .continue
            }
            if c >= UInt8(ascii: "1") && c <= UInt8(ascii: "9") {
                step = .one
                return .continue
            }
            return fail(c, "in numeric literal")
        case .one:
            if Self.isDigit(c) {
                step = .one
                return .continue
            }
            return zeroState(c)
        case .zero:
            return zeroState(c)
        case .dot:
            if Self.isDigit(c) {
                step = .dot0
                return .continue
            }
            return fail(c, "after decimal point in numeric literal")
        case .dot0:
            if Self.isDigit(c) { return .continue }
            if c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                step = .e
                return .continue
            }
            return endValue(c)
        case .e:
            if c == UInt8(ascii: "+") || c == UInt8(ascii: "-") {
                step = .eSign
                return .continue
            }
            return eSign(c)
        case .eSign:
            return eSign(c)
        case .e0:
            if Self.isDigit(c) { return .continue }
            return endValue(c)
        case .t: return letter(c, "r", .tr, "in literal true (expecting 'r')")
        case .tr: return letter(c, "u", .tru, "in literal true (expecting 'u')")
        case .tru: return letter(c, "e", .endValue, "in literal true (expecting 'e')")
        case .f: return letter(c, "a", .fa, "in literal false (expecting 'a')")
        case .fa: return letter(c, "l", .fal, "in literal false (expecting 'l')")
        case .fal: return letter(c, "s", .fals, "in literal false (expecting 's')")
        case .fals: return letter(c, "e", .endValue, "in literal false (expecting 'e')")
        case .n: return letter(c, "u", .nu, "in literal null (expecting 'u')")
        case .nu: return letter(c, "l", .nul, "in literal null (expecting 'l')")
        case .nul: return letter(c, "l", .endValue, "in literal null (expecting 'l')")
        case .error: return .error
        }
    }

    private mutating func letter(_ c: UInt8, _ want: Unicode.Scalar, _ next: State, _ context: String) -> Op {
        if c == UInt8(want.value) {
            step = next
            return .continue
        }
        return fail(c, context)
    }

    private mutating func beginValue(_ c: UInt8) -> Op {
        if Self.isSpace(c) { return .skipSpace }
        switch c {
        case UInt8(ascii: "{"):
            step = .beginStringOrEmpty
            return push(c, .objectKey, .beginObject)
        case UInt8(ascii: "["):
            step = .beginValueOrEmpty
            return push(c, .arrayValue, .beginArray)
        case UInt8(ascii: "\""): step = .inString
        case UInt8(ascii: "-"): step = .neg
        case UInt8(ascii: "0"): step = .zero
        case UInt8(ascii: "t"): step = .t
        case UInt8(ascii: "f"): step = .f
        case UInt8(ascii: "n"): step = .n
        case UInt8(ascii: "1")...UInt8(ascii: "9"): step = .one
        default: return fail(c, "looking for beginning of value")
        }
        return .beginLiteral
    }

    private mutating func beginString(_ c: UInt8) -> Op {
        if Self.isSpace(c) { return .skipSpace }
        if c == UInt8(ascii: "\"") {
            step = .inString
            return .beginLiteral
        }
        return fail(c, "looking for beginning of object key string")
    }

    /// Go's `stateEndValue`.
    mutating func endValue(_ c: UInt8) -> Op {
        guard let state = parseState.last else {
            step = .endTop
            endTop = true
            return endTopState(c)
        }
        if Self.isSpace(c) {
            step = .endValue
            return .skipSpace
        }
        switch state {
        case .objectKey:
            if c == UInt8(ascii: ":") {
                parseState[parseState.count - 1] = .objectValue
                step = .beginValue
                return .objectKey
            }
            return fail(c, "after object key")
        case .objectValue:
            if c == UInt8(ascii: ",") {
                parseState[parseState.count - 1] = .objectKey
                step = .beginString
                return .objectValue
            }
            if c == UInt8(ascii: "}") {
                pop()
                return .endObject
            }
            return fail(c, "after object key:value pair")
        case .arrayValue:
            if c == UInt8(ascii: ",") {
                step = .beginValue
                return .arrayValue
            }
            if c == UInt8(ascii: "]") {
                pop()
                return .endArray
            }
            return fail(c, "after array element")
        }
    }

    private mutating func endTopState(_ c: UInt8) -> Op {
        if !Self.isSpace(c) { _ = fail(c, "after top-level value") }
        return .end
    }

    private mutating func zeroState(_ c: UInt8) -> Op {
        if c == UInt8(ascii: ".") {
            step = .dot
            return .continue
        }
        if c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
            step = .e
            return .continue
        }
        return endValue(c)
    }

    private mutating func eSign(_ c: UInt8) -> Op {
        if Self.isDigit(c) {
            step = .e0
            return .continue
        }
        return fail(c, "in exponent of numeric literal")
    }
}

enum GoJSONText {
    static let hex = Array("0123456789abcdef".utf8)

    /// Go's `checkValid`: nil, or the syntax error of `data`.
    static func check(_ data: [UInt8]) -> (message: String, offset: Int64)? {
        var scanner = GoJSONScanner()
        for c in data {
            scanner.bytes += 1
            if scanner.feed(c) == .error { return scanner.error }
        }
        if scanner.eof() == .error { return scanner.error }
        return nil
    }

    /// What `Decoder.readValue` finds in `data`, the buffered input from the
    /// start of a value: the length of the value and the bytes Go's scanner
    /// counted, or a syntax error after `count` bytes, or that more input is
    /// needed (`-1`), or at the end of the input that a value was cut off
    /// (`-2`) or that there was space alone (`-1`).
    static func valueEnd(_ data: [UInt8], atEnd: Bool) -> (length: Int, count: Int, message: String) {
        var scanner = GoJSONScanner()
        var count = 0
        for (index, c) in data.enumerated() {
            count += 1
            switch scanner.feed(c) {
            case .end:
                return (index, count - 1, "")
            case .endObject, .endArray:
                if scanner.endValue(0x20) == .end { return (index + 1, count, "") }
            case .error:
                return (-1, count, scanner.error?.message ?? "")
            default:
                break
            }
        }
        guard atEnd else { return (-1, 0, "") }
        if scanner.feed(0x20) == .end { return (data.count, count, "") }
        return (data.contains { !GoJSONScanner.isSpace($0) } ? -2 : -1, 0, "")
    }

    /// Go's `appendCompact`.
    static func compact(
        _ destination: [UInt8], _ source: [UInt8], escape: Bool
    ) -> (bytes: [UInt8], error: (message: String, offset: Int64)?) {
        var dst = destination
        var scanner = GoJSONScanner()
        var start = 0
        for (i, c) in source.enumerated() {
            if escape && (c == UInt8(ascii: "<") || c == UInt8(ascii: ">") || c == UInt8(ascii: "&")) {
                if start < i { dst += source[start..<i] }
                dst += [0x5C, 0x75, 0x30, 0x30, hex[Int(c >> 4)], hex[Int(c & 0xF)]]
                start = i + 1
            }
            if escape && c == 0xE2 && i + 2 < source.count && source[i + 1] == 0x80
                && source[i + 2] & ~1 == 0xA8
            {
                if start < i { dst += source[start..<i] }
                dst += [0x5C, 0x75, 0x32, 0x30, 0x32, hex[Int(source[i + 2] & 0xF)]]
                start = i + 3
            }
            let op = scanner.feed(c)
            if op >= .skipSpace {
                if op == .error { break }
                if start < i { dst += source[start..<i] }
                start = i + 1
            }
        }
        if scanner.eof() == .error { return (destination, scanner.error) }
        if start < source.count { dst += source[start...] }
        return (dst, nil)
    }

    /// Go's `appendIndent`.
    static func indent(
        _ destination: [UInt8], _ source: [UInt8], prefix: [UInt8], indent: [UInt8]
    ) -> (bytes: [UInt8], error: (message: String, offset: Int64)?) {
        var dst = destination
        var scanner = GoJSONScanner()
        var needIndent = false
        var depth = 0
        func newline() {
            dst.append(0x0A)
            dst += prefix
            for _ in 0..<max(0, depth) { dst += indent }
        }
        for c in source {
            scanner.bytes += 1
            let op = scanner.feed(c)
            if op == .skipSpace { continue }
            if op == .error { break }
            if needIndent && op != .endObject && op != .endArray {
                needIndent = false
                depth += 1
                newline()
            }
            if op == .continue {
                dst.append(c)
                continue
            }
            switch c {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                needIndent = true
                dst.append(c)
            case UInt8(ascii: ","):
                dst.append(c)
                newline()
            case UInt8(ascii: ":"):
                dst += [c, 0x20]
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if needIndent {
                    needIndent = false
                } else {
                    depth -= 1
                    newline()
                }
                dst.append(c)
            default:
                dst.append(c)
            }
        }
        if scanner.eof() == .error { return (destination, scanner.error) }
        return (dst, nil)
    }

    /// Go's `appendString`: `text` as a JSON string.
    static func appendString(_ dst: inout [UInt8], _ text: some Collection<UInt8>, escapeHTML: Bool) {
        dst.append(0x22)
        let src = Array(text)
        var start = 0
        var i = 0
        while i < src.count {
            let b = src[i]
            if b < 0x80 {
                if isSafe(b, html: escapeHTML) {
                    i += 1
                    continue
                }
                dst += src[start..<i]
                switch b {
                case 0x5C, 0x22: dst += [0x5C, b]
                case 0x08: dst += [0x5C, UInt8(ascii: "b")]
                case 0x0C: dst += [0x5C, UInt8(ascii: "f")]
                case 0x0A: dst += [0x5C, UInt8(ascii: "n")]
                case 0x0D: dst += [0x5C, UInt8(ascii: "r")]
                case 0x09: dst += [0x5C, UInt8(ascii: "t")]
                default: dst += [0x5C, 0x75, 0x30, 0x30, hex[Int(b >> 4)], hex[Int(b & 0xF)]]
                }
                i += 1
                start = i
                continue
            }
            let (scalar, size) = decodeRune(src, at: i)
            if scalar == nil {
                dst += src[start..<i]
                dst += Array(#"�"#.utf8)
                i += 1
                start = i
                continue
            }
            if let scalar, scalar.value == 0x2028 || scalar.value == 0x2029 {
                dst += src[start..<i]
                dst += [0x5C, 0x75, 0x32, 0x30, 0x32, hex[Int(scalar.value & 0xF)]]
                i += size
                start = i
                continue
            }
            i += size
        }
        dst += src[start...]
        dst.append(0x22)
    }

    /// Whether Go writes the ASCII byte `b` as it is in a string.
    private static func isSafe(_ b: UInt8, html: Bool) -> Bool {
        if b < 0x20 || b == 0x22 || b == 0x5C { return false }
        if html && (b == UInt8(ascii: "<") || b == UInt8(ascii: ">") || b == UInt8(ascii: "&")) {
            return false
        }
        return true
    }

    /// Go's `utf8.DecodeRune`: the scalar at `index` and its length, or nil
    /// and 1 for a byte that begins none.
    static func decodeRune(_ bytes: [UInt8], at index: Int) -> (Unicode.Scalar?, Int) {
        let first = bytes[index]
        if first < 0x80 { return (Unicode.Scalar(first), 1) }
        let length: Int
        var value: UInt32
        var low: UInt8 = 0x80
        var high: UInt8 = 0xBF
        switch first {
        case 0xC2...0xDF: length = 2; value = UInt32(first & 0x1F)
        case 0xE0...0xEF:
            length = 3
            value = UInt32(first & 0x0F)
            if first == 0xE0 { low = 0xA0 }
            if first == 0xED { high = 0x9F }
        case 0xF0...0xF4:
            length = 4
            value = UInt32(first & 0x07)
            if first == 0xF0 { low = 0x90 }
            if first == 0xF4 { high = 0x8F }
        default: return (nil, 1)
        }
        guard index + length <= bytes.count else { return (nil, 1) }
        for k in 1..<length {
            let byte = bytes[index + k]
            let (lo, hi) = k == 1 ? (low, high) : (UInt8(0x80), UInt8(0xBF))
            guard byte >= lo, byte <= hi else { return (nil, 1) }
            value = value << 6 | UInt32(byte & 0x3F)
        }
        return (Unicode.Scalar(value), length)
    }

    /// Go's `isValidNumber`.
    static func isValidNumber(_ text: [UInt8]) -> Bool {
        var s = text[...]
        func digit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        if s.isEmpty { return false }
        if s.first == UInt8(ascii: "-") {
            s = s.dropFirst()
            if s.isEmpty { return false }
        }
        if s.first == UInt8(ascii: "0") {
            s = s.dropFirst()
        } else if let c = s.first, c >= UInt8(ascii: "1"), c <= UInt8(ascii: "9") {
            s = s.dropFirst()
            while let c = s.first, digit(c) { s = s.dropFirst() }
        } else {
            return false
        }
        if s.count >= 2, s.first == UInt8(ascii: "."), digit(s[s.startIndex + 1]) {
            s = s.dropFirst(2)
            while let c = s.first, digit(c) { s = s.dropFirst() }
        }
        if s.count >= 2, s.first == UInt8(ascii: "e") || s.first == UInt8(ascii: "E") {
            s = s.dropFirst()
            if s.first == UInt8(ascii: "+") || s.first == UInt8(ascii: "-") {
                s = s.dropFirst()
                if s.isEmpty { return false }
            }
            while let c = s.first, digit(c) { s = s.dropFirst() }
        }
        return s.isEmpty
    }

    // MARK: base64

    static let base64Alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// `base64.StdEncoding.EncodeToString`.
    static func base64(_ src: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity((src.count + 2) / 3 * 4)
        var i = 0
        while i + 3 <= src.count {
            let value = UInt32(src[i]) << 16 | UInt32(src[i + 1]) << 8 | UInt32(src[i + 2])
            out += [
                base64Alphabet[Int(value >> 18 & 0x3F)], base64Alphabet[Int(value >> 12 & 0x3F)],
                base64Alphabet[Int(value >> 6 & 0x3F)], base64Alphabet[Int(value & 0x3F)],
            ]
            i += 3
        }
        let remain = src.count - i
        if remain > 0 {
            var value = UInt32(src[i]) << 16
            if remain == 2 { value |= UInt32(src[i + 1]) << 8 }
            out += [base64Alphabet[Int(value >> 18 & 0x3F)], base64Alphabet[Int(value >> 12 & 0x3F)]]
            out += remain == 2 ? [base64Alphabet[Int(value >> 6 & 0x3F)], 0x3D] : [0x3D, 0x3D]
        }
        return out
    }

    /// `base64.StdEncoding.Decode` into a buffer of `DecodedLen`: the bytes,
    /// or the offset of Go's `CorruptInputError`.
    static func unbase64(_ src: [UInt8]) -> (bytes: [UInt8], corruptAt: Int?) {
        var decodeMap = [UInt8](repeating: 0xFF, count: 256)
        for (index, byte) in base64Alphabet.enumerated() { decodeMap[Int(byte)] = UInt8(index) }
        var out: [UInt8] = []
        var si = 0
        let pad = UInt8(ascii: "=")
        func isNewline(_ c: UInt8) -> Bool { c == 0x0A || c == 0x0D }
        while si < src.count {
            var dbuf: [UInt8] = [0, 0, 0, 0]
            var dlen = 4
            var trailing: Int?
            var j = 0
            while j < 4 {
                if src.count == si {
                    if j == 0 { return (out, nil) }
                    return (out, si - j)
                }
                let c = src[si]
                si += 1
                let value = decodeMap[Int(c)]
                if value != 0xFF {
                    dbuf[j] = value
                    j += 1
                    continue
                }
                if isNewline(c) { continue }
                if c != pad { return (out, si - 1) }
                switch j {
                case 0, 1: return (out, si - 1)
                case 2:
                    while si < src.count && isNewline(src[si]) { si += 1 }
                    if si == src.count { return (out, src.count) }
                    if src[si] != pad { return (out, si - 1) }
                    si += 1
                default: break
                }
                while si < src.count && isNewline(src[si]) { si += 1 }
                if si < src.count { trailing = si }
                dlen = j
                break
            }
            let value = UInt32(dbuf[0]) << 18 | UInt32(dbuf[1]) << 12 | UInt32(dbuf[2]) << 6 | UInt32(dbuf[3])
            let bytes = [UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8),
                         UInt8(truncatingIfNeeded: value)]
            out += bytes[0..<(dlen - 1)]
            if let trailing { return (out, trailing) }
        }
        return (out, nil)
    }
}
