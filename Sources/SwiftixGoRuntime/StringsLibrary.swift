/// Native implementations of the supported Go `strings` functions, and the Go
/// `unicode` character functions they and `fmt` rest on.
///
/// Guest byte loops cost several VM instructions per byte, so searching,
/// splitting, and joining run natively on the UTF-8 bytes with Go semantics.
/// Pure functions of their arguments; no process or executor state.

/// A Go `strings` function, encoded in images as one byte after its opcode.
public enum GoStringsFunction: UInt8, Sendable, Equatable, CaseIterable {
    case contains = 0
    case count = 1
    case hasPrefix = 2
    case hasSuffix = 3
    case index = 4
    case join = 5
    case repeatString = 6
    case split = 7
    case lastIndex = 8
    case trimSpace = 9

    /// The exported Go name, such as `Index`.
    public var goName: String {
        switch self {
        case .contains: return "Contains"
        case .count: return "Count"
        case .hasPrefix: return "HasPrefix"
        case .hasSuffix: return "HasSuffix"
        case .index: return "Index"
        case .join: return "Join"
        case .repeatString: return "Repeat"
        case .split: return "Split"
        case .lastIndex: return "LastIndex"
        case .trimSpace: return "TrimSpace"
        }
    }

    public init?(goName: String) {
        guard let function = Self.allCases.first(where: { $0.goName == goName }) else {
            return nil
        }
        self = function
    }

    /// Number of operands the instruction pops.
    public var argumentCount: Int {
        self == .trimSpace ? 1 : 2
    }
}

enum GoStrings {
    /// Byte offset of the first occurrence of `needle` at or after `start`, or
    /// nil. An empty needle matches at `start`.
    static func firstIndex(
        of needle: [UInt8],
        in haystack: [UInt8],
        from start: Int = 0
    ) -> Int? {
        guard !needle.isEmpty else { return start <= haystack.count ? start : nil }
        guard needle.count <= haystack.count else { return nil }
        let first = needle[0]
        var index = start
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first {
                var matched = 1
                while matched < needle.count, haystack[index + matched] == needle[matched] {
                    matched += 1
                }
                if matched == needle.count { return index }
            }
            index += 1
        }
        return nil
    }

    static func index(_ s: String, _ substring: String) -> Int {
        firstIndex(of: Array(substring.utf8), in: Array(s.utf8)) ?? -1
    }

    static func lastIndex(_ s: String, _ substring: String) -> Int {
        let haystack = Array(s.utf8)
        let needle = Array(substring.utf8)
        guard needle.count <= haystack.count else { return -1 }
        var index = haystack.count - needle.count
        while index >= 0 {
            if haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index -= 1
        }
        return -1
    }

    /// Non-overlapping occurrences; an empty substring counts the positions
    /// around each character, as in Go.
    static func count(_ s: String, _ substring: String) -> Int {
        if substring.isEmpty { return s.unicodeScalars.count + 1 }
        let haystack = Array(s.utf8)
        let needle = Array(substring.utf8)
        var total = 0
        var start = 0
        while let found = firstIndex(of: needle, in: haystack, from: start) {
            total += 1
            start = found + needle.count
        }
        return total
    }

    /// Go's `strings.Split`: an empty separator splits after each UTF-8
    /// character, and an empty string yields one empty element.
    static func split(_ s: String, _ separator: String) -> [String] {
        if separator.isEmpty {
            return s.unicodeScalars.map { String($0) }
        }
        let haystack = Array(s.utf8)
        let needle = Array(separator.utf8)
        var parts: [String] = []
        var start = 0
        while let found = firstIndex(of: needle, in: haystack, from: start) {
            parts.append(String(decoding: haystack[start..<found], as: UTF8.self))
            start = found + needle.count
        }
        parts.append(String(decoding: haystack[start...], as: UTF8.self))
        return parts
    }

    /// Go's Unicode white space for `TrimSpace`.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
            0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    static func trimSpace(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
            let last = scalars.lastIndex(where: { !isSpace($0) })
        else { return "" }
        return String(scalars[first...last])
    }

    /// Go's `strings.Fields`: the runs of characters between white space.
    static func fields(_ s: String) -> [String] {
        s.unicodeScalars.split(whereSeparator: isSpace).map { String($0) }
    }

    /// Go's `strings.ToUpper` or `strings.ToLower`: each code point mapped by
    /// itself, so `ß` stays `ß` and the result can differ in byte length.
    static func mapped(_ s: String, toUpper: Bool) -> String {
        var result = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            result.append(toUpper ? GoUnicode.toUpper(scalar) : GoUnicode.toLower(scalar))
        }
        return String(result)
    }

    /// Go's `strings.TrimPrefix`. Both strings are valid UTF-8, so a byte
    /// prefix ends on a character boundary.
    static func trimPrefix(_ s: String, _ prefix: String) -> String {
        guard s.utf8.starts(with: prefix.utf8) else { return s }
        return String(decoding: s.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    }

    /// Go's `strings.TrimSuffix`.
    static func trimSuffix(_ s: String, _ suffix: String) -> String {
        guard s.utf8.reversed().starts(with: suffix.utf8.reversed()) else { return s }
        return String(decoding: s.utf8.dropLast(suffix.utf8.count), as: UTF8.self)
    }
}

/// Go's `unicode` and `strconv` character functions over `GoUnicodeTables`,
/// which pins them to the reference Go release instead of the host's Unicode
/// version.
enum GoUnicode {
    /// Go's `unicode.ToUpper`.
    static func toUpper(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        mapped(scalar, lowerCase: false)
    }

    /// Go's `unicode.ToLower`.
    static func toLower(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        mapped(scalar, lowerCase: true)
    }

    /// Go's `strconv.IsPrint`: letters, marks, numbers, punctuation, symbols,
    /// and the ASCII space.
    static func isPrint(_ scalar: Unicode.Scalar) -> Bool {
        let ranges = GoUnicodeTables.printableRanges
        var low = 0
        var high = ranges.count / 2
        while low < high {
            let middle = (low + high) / 2
            if scalar.value < ranges[middle * 2] {
                high = middle
            } else if scalar.value > ranges[middle * 2 + 1] {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    /// Go's `unicode.to`: a binary search of the case ranges.
    private static func mapped(_ scalar: Unicode.Scalar, lowerCase: Bool) -> Unicode.Scalar {
        let ranges = GoUnicodeTables.caseRanges
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            let range = ranges[middle]
            if scalar.value < range.first {
                high = middle
            } else if scalar.value > range.last {
                low = middle + 1
            } else {
                let delta = lowerCase ? range.toLower : range.toUpper
                let value: UInt32
                if delta == GoUnicodeTables.alternating {
                    // A run of upper/lower pairs that starts with an upper
                    // case letter: even offsets are upper, odd ones lower.
                    value = range.first + (((scalar.value - range.first) & ~1) | (lowerCase ? 1 : 0))
                } else {
                    value = UInt32(Int64(scalar.value) + Int64(delta))
                }
                return Unicode.Scalar(value) ?? scalar
            }
        }
        return scalar
    }
}
