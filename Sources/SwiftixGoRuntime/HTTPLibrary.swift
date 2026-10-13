/// The natives of `net/http`.
///
/// The package is Go source that is compiled with the program (the compiler's
/// `GoEmbeddedLibrary`), so that a server can run the program's handlers. What
/// it leaves to the VM is here: work that goes over a message byte by byte,
/// which costs one VM instruction this way and several per byte in guest
/// code. Each function follows the Go release the toolchain takes as its
/// reference, and names where.
///
/// Everything in this file is a pure function of its arguments; the VM reads
/// the operands and the clock.

enum GoHTTP {
    /// Reserved call names of the natives, with their operand counts.
    static let argumentCounts: [String: Int] = [
        "$http.CanonicalHeaderKey": 1,
        "$http.DetectContentType": 1,
        "$http.lineEnd": 2,
        "$http.formatTime": 2,
        "$http.remoteAddr": 1,
        "$http.validToken": 1,
        "$http.validHeaderValue": 1,
    ]

    // MARK: Header names

    /// Whether `byte` may be part of a header name: a `token` character of
    /// RFC 7230. `textproto.validHeaderFieldByte`.
    static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return true
        default:
            return "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    /// Whether `text` is a `token`: `httpguts.ValidHeaderFieldName`, and the
    /// test of a request's method.
    static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy(isTokenByte)
    }

    /// Whether `text` may be the value of a header field: no control byte
    /// but the tab. `httpguts.ValidHeaderFieldValue`.
    static func isHeaderValue(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7F) }
    }

    /// The canonical form of a header name: the first letter and each one
    /// after a hyphen in upper case, the rest in lower case. A name that is
    /// not a token is returned as it is. `textproto.CanonicalMIMEHeaderKey`.
    static func canonicalHeaderKey(_ key: String) -> String {
        var bytes = Array(key.utf8)
        guard bytes.allSatisfy(isTokenByte) else { return key }
        var upper = true
        for index in bytes.indices {
            let byte = bytes[index]
            if upper, byte >= UInt8(ascii: "a"), byte <= UInt8(ascii: "z") {
                bytes[index] = byte - 0x20
            } else if !upper, byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") {
                bytes[index] = byte + 0x20
            }
            upper = byte == UInt8(ascii: "-")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Messages

    /// Where the line that begins at or after `start` ends: the index after
    /// its line feed, or -1 when the bytes have none there yet.
    static func lineEnd(_ bytes: [UInt8], from start: Int) -> Int {
        guard start >= 0, start < bytes.count,
            let lineFeed = bytes[start...].firstIndex(of: 0x0A)
        else { return -1 }
        return lineFeed + 1
    }

    /// How an instant is written.
    enum TimeLayout: Int64 {
        /// `Mon, 02 Jan 2006 15:04:05 GMT`, Go's `http.TimeFormat`, as in a
        /// `Date` header.
        case header = 0
        /// `2006/01/02 15:04:05`, as Go's `log` package begins a line.
        case log = 1
    }

    /// `seconds` since the Unix epoch, written in UTC as `layout` says.
    static func formatTime(unixSeconds seconds: Int64, layout: TimeLayout) -> String {
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let secondOfDay = seconds - days * 86_400
        // Days to a civil date, in the proleptic Gregorian calendar.
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        // The epoch was a Thursday.
        let weekday = Int(((days % 7) + 11) % 7)
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        func padded(_ value: Int64, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        let clock =
            "\(padded(secondOfDay / 3_600, 2)):\(padded(secondOfDay % 3_600 / 60, 2)):"
            + padded(secondOfDay % 60, 2)
        switch layout {
        case .header:
            return "\(weekdays[weekday]), \(padded(day, 2)) \(months[Int(month) - 1]) "
                + "\(padded(year, 4)) \(clock) GMT"
        case .log:
            return "\(padded(year, 4))/\(padded(month, 2))/\(padded(day, 2)) \(clock)"
        }
    }

    // MARK: Content types

    /// How many bytes the sniffing algorithm looks at.
    static let sniffLength = 512

    /// The content type of data that begins with `data`, by the algorithm
    /// of https://mimesniff.spec.whatwg.org/ as Go's `http.DetectContentType`
    /// implements it: the first signature that matches, in Go's order, and
    /// `application/octet-stream` when none does.
    static func detectContentType(_ data: [UInt8]) -> String {
        let data = Array(data.prefix(sniffLength))
        let firstNonSpace = data.firstIndex { !isSpace($0) } ?? data.count
        for signature in signatures {
            if let type = signature.match(data, firstNonSpace) { return type }
        }
        return "application/octet-stream"
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    private enum Signature {
        /// An HTML tag, in either case, after any white space, and then a
        /// space or `>`.
        case html(String)
        /// The bytes themselves.
        case exact([UInt8], String)
        /// The bytes under a mask, after any white space when `skipsSpace`.
        case masked(mask: [UInt8], pattern: [UInt8], skipsSpace: Bool, String)
        case mp4
        /// No byte that only binary data has.
        case text

        func match(_ data: [UInt8], _ firstNonSpace: Int) -> String? {
            switch self {
            case .html(let tag):
                let rest = data[firstNonSpace...]
                let tagBytes = Array(tag.utf8)
                guard rest.count >= tagBytes.count + 1 else { return nil }
                for (offset, expected) in tagBytes.enumerated() {
                    var byte = rest[rest.startIndex + offset]
                    if expected >= UInt8(ascii: "A"), expected <= UInt8(ascii: "Z") { byte &= 0xDF }
                    if byte != expected { return nil }
                }
                let terminator = rest[rest.startIndex + tagBytes.count]
                guard terminator == UInt8(ascii: " ") || terminator == UInt8(ascii: ">") else {
                    return nil
                }
                return "text/html; charset=utf-8"
            case .exact(let bytes, let type):
                return data.starts(with: bytes) ? type : nil
            case .masked(let mask, let pattern, let skipsSpace, let type):
                let rest = skipsSpace ? data[firstNonSpace...] : data[...]
                guard mask.count == pattern.count, rest.count >= pattern.count else { return nil }
                for (offset, expected) in pattern.enumerated()
                where rest[rest.startIndex + offset] & mask[offset] != expected {
                    return nil
                }
                return type
            case .mp4:
                guard data.count >= 12 else { return nil }
                let boxSize = data[..<4].reduce(0) { $0 << 8 | Int($1) }
                guard data.count >= boxSize, boxSize % 4 == 0,
                    Array(data[4..<8]) == Array("ftyp".utf8)
                else { return nil }
                var start = 8
                while start < boxSize {
                    // The four bytes after the major brand are its version.
                    if start != 12, Array(data[start..<(start + 3)]) == Array("mp4".utf8) {
                        return "video/mp4"
                    }
                    start += 4
                }
                return nil
            case .text:
                for byte in data[firstNonSpace...] {
                    switch byte {
                    case 0x00...0x08, 0x0B, 0x0E...0x1A, 0x1C...0x1F: return nil
                    default: continue
                    }
                }
                return "text/plain; charset=utf-8"
            }
        }
    }

    private static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// The table of section 6 of the specification, in Go's order.
    private static let signatures: [Signature] = {
        let full4: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
        let none4: [UInt8] = [0, 0, 0, 0]
        var table: [Signature] = [
            "<!DOCTYPE HTML", "<HTML", "<HEAD", "<SCRIPT", "<IFRAME", "<H1", "<DIV", "<FONT",
            "<TABLE", "<A", "<STYLE", "<TITLE", "<B", "<BODY", "<BR", "<P", "<!--",
        ].map(Signature.html)
        table += [
            .masked(
                mask: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF], pattern: bytes("<?xml"), skipsSpace: true,
                "text/xml; charset=utf-8"),
            .exact(bytes("%PDF-"), "application/pdf"),
            .exact(bytes("%!PS-Adobe-"), "application/postscript"),
            // Byte order marks.
            .masked(
                mask: [0xFF, 0xFF, 0, 0], pattern: [0xFE, 0xFF, 0, 0], skipsSpace: false,
                "text/plain; charset=utf-16be"),
            .masked(
                mask: [0xFF, 0xFF, 0, 0], pattern: [0xFF, 0xFE, 0, 0], skipsSpace: false,
                "text/plain; charset=utf-16le"),
            .masked(
                mask: [0xFF, 0xFF, 0xFF, 0], pattern: [0xEF, 0xBB, 0xBF, 0], skipsSpace: false,
                "text/plain; charset=utf-8"),
            // Images.
            .exact([0, 0, 1, 0], "image/x-icon"),
            .exact([0, 0, 2, 0], "image/x-icon"),
            .exact(bytes("BM"), "image/bmp"),
            .exact(bytes("GIF87a"), "image/gif"),
            .exact(bytes("GIF89a"), "image/gif"),
            .masked(
                mask: full4 + none4 + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
                pattern: bytes("RIFF") + none4 + bytes("WEBPVP"), skipsSpace: false, "image/webp"),
            .exact([0x89] + bytes("PNG") + [0x0D, 0x0A, 0x1A, 0x0A], "image/png"),
            .exact([0xFF, 0xD8, 0xFF], "image/jpeg"),
            // Audio and video.
            .masked(
                mask: full4 + none4 + full4, pattern: bytes("FORM") + none4 + bytes("AIFF"),
                skipsSpace: false, "audio/aiff"),
            .masked(mask: [0xFF, 0xFF, 0xFF], pattern: bytes("ID3"), skipsSpace: false, "audio/mpeg"),
            .masked(
                mask: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF], pattern: bytes("OggS") + [0],
                skipsSpace: false, "application/ogg"),
            .masked(
                mask: full4 + full4, pattern: bytes("MThd") + [0, 0, 0, 6], skipsSpace: false,
                "audio/midi"),
            .masked(
                mask: full4 + none4 + full4, pattern: bytes("RIFF") + none4 + bytes("AVI "),
                skipsSpace: false, "video/avi"),
            .masked(
                mask: full4 + none4 + full4, pattern: bytes("RIFF") + none4 + bytes("WAVE"),
                skipsSpace: false, "audio/wave"),
            .mp4,
            .exact([0x1A, 0x45, 0xDF, 0xA3], "video/webm"),
            // Fonts: 34 zero bytes that are not looked at, then "LP".
            .masked(
                mask: [UInt8](repeating: 0, count: 34) + [0xFF, 0xFF],
                pattern: [UInt8](repeating: 0, count: 34) + bytes("LP"), skipsSpace: false,
                "application/vnd.ms-fontobject"),
            .exact([0, 1, 0, 0], "font/ttf"),
            .exact(bytes("OTTO"), "font/otf"),
            .exact(bytes("ttcf"), "font/collection"),
            .exact(bytes("wOFF"), "font/woff"),
            .exact(bytes("wOF2"), "font/woff2"),
            // Archives.
            .exact([0x1F, 0x8B, 0x08], "application/x-gzip"),
            .exact(bytes("PK") + [0x03, 0x04], "application/zip"),
            .exact(bytes("Rar!") + [0x1A, 0x07, 0x00], "application/x-rar-compressed"),
            .exact(bytes("Rar!") + [0x1A, 0x07, 0x01, 0x00], "application/x-rar-compressed"),
            .exact([0x00, 0x61, 0x73, 0x6D], "application/wasm"),
            .text,
        ]
        return table
    }()
}

/// The natives of `net/url`: escaping, which goes over a string byte by
/// byte. Each follows the function of the same name in Go's `net/url`.
enum GoURL {
    /// Reserved call names of the natives, with their operand counts.
    static let argumentCounts: [String: Int] = [
        "$url.unescape": 2,
        "$url.escape": 2,
        "$url.validEncoded": 2,
        "$url.hasControlByte": 1,
    ]

    /// The part of a URL a string belongs to, which decides what is
    /// escaped in it. The numbers are those of the package's source.
    enum Mode: Int64 {
        case path = 1
        case pathSegment
        case host
        case zone
        case userPassword
        case queryComponent
        case fragment
    }

    /// Why a string could not be unescaped.
    enum Failure: Error, Equatable {
        /// A `%` that two hexadecimal digits do not follow, with up to
        /// three bytes from it.
        case escape(String)
        /// A byte a host name cannot have.
        case host(String)
    }

    /// Whether `text` has an ASCII control byte, which no URL may.
    static func hasControlByte(_ text: String) -> Bool {
        text.utf8.contains { $0 < 0x20 || $0 == 0x7F }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Whether `byte` must be written as `%XX` in the part `mode` names.
    static func shouldEscape(_ byte: UInt8, _ mode: Mode) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"):
            return false
        default: break
        }
        if mode == .host || mode == .zone, "!$&'()*+,;=:[]<>\"".utf8.contains(byte) {
            return false
        }
        if "-_.~".utf8.contains(byte) { return false }
        if "$&+,/:;=?@".utf8.contains(byte) {
            switch mode {
            case .path: return byte == UInt8(ascii: "?")
            case .pathSegment: return "/;,?".utf8.contains(byte)
            case .userPassword: return "@/?:".utf8.contains(byte)
            case .queryComponent: return true
            case .fragment: return false
            case .host, .zone: break
            }
        }
        if mode == .fragment, "!()*".utf8.contains(byte) { return false }
        return true
    }

    /// `text` with every `%XX` replaced by the byte it stands for, and in
    /// a query component every `+` by a space.
    static func unescape(_ text: String, _ mode: Mode) -> Result<[UInt8], Failure> {
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, let high = hexValue(bytes[index + 1]),
                    let low = hexValue(bytes[index + 2])
                else {
                    return .failure(
                        .escape(String(decoding: bytes[index...].prefix(3), as: UTF8.self)))
                }
                let escape = String(decoding: bytes[index..<(index + 3)], as: UTF8.self)
                let value = high << 4 | low
                // In a host only bytes outside ASCII are escaped, and a
                // zone escapes what it could have written directly.
                if mode == .host, high < 8, escape != "%25" { return .failure(.escape(escape)) }
                if mode == .zone, escape != "%25", value != UInt8(ascii: " "),
                    shouldEscape(value, .host)
                {
                    return .failure(.escape(escape))
                }
                result.append(value)
                index += 3
                continue
            }
            if byte == UInt8(ascii: "+") {
                result.append(mode == .queryComponent ? UInt8(ascii: " ") : byte)
            } else {
                if mode == .host || mode == .zone, byte < 0x80, shouldEscape(byte, mode) {
                    return .failure(.host(String(decoding: [byte], as: UTF8.self)))
                }
                result.append(byte)
            }
            index += 1
        }
        return .success(result)
    }

    /// `text` with every byte that `mode` does not allow written as `%XX`,
    /// and in a query component every space as `+`.
    static func escape(_ text: String, _ mode: Mode) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if byte == UInt8(ascii: " "), mode == .queryComponent {
                result.append(UInt8(ascii: "+"))
            } else if shouldEscape(byte, mode) {
                result.append(UInt8(ascii: "%"))
                result.append(digits[Int(byte >> 4)])
                result.append(digits[Int(byte & 15)])
            } else {
                result.append(byte)
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Whether `text` is escaped as `mode` asks, so that it can stand for
    /// itself in a URL.
    static func isValidEncoded(_ text: String, _ mode: Mode) -> Bool {
        text.utf8.allSatisfy { "!$&'()*+,;=:@[]%".utf8.contains($0) || !shouldEscape($0, mode) }
    }
}
