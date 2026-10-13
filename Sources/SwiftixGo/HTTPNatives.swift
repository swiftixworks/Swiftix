/// The natives of `net/http`, which the Go source of the package calls.
///
/// The package is written in Go (see `GoEmbeddedLibrary`) and imports its own
/// path to reach these: `nethttp.DetectContentType(p)` in its source is the
/// native, as `strconv.Itoa` is one in a program. A program does not reach
/// them. Its `http.DetectContentType` is the function the package declares,
/// because the linker resolves every `http.X` of a program to the package.
/// The VM's side is `GoHTTP`.
extension GoStandardLibrary {
    static func httpNativeFunction(_ member: String) -> GoNativeFunction? {
        let bytes = GoType.slice(GoPredeclared.byte)
        let signature: (parameters: [GoType], result: GoType)
        switch member {
        // The canonical form of a header name: `Content-Type`.
        case "CanonicalHeaderKey": signature = ([.string], .string)
        // The content type that data beginning with these bytes has.
        case "DetectContentType": signature = ([bytes], .string)
        // Where the line that begins at an index ends: the index after
        // its line feed, or -1 when it has not arrived.
        case "lineEnd": signature = ([bytes, .int], .int)
        // Seconds since the epoch, as a `Date` header writes them (0) or
        // as a line of a log begins (1).
        case "formatTime": signature = ([.int, .int], .string)
        // `conn.RemoteAddr().String()`.
        case "remoteAddr": signature = ([.named("net.Conn")], .string)
        // Whether a method or a header name is a token of RFC 7230.
        case "validToken": signature = ([.string], .bool)
        // Whether a header value has no control byte but the tab.
        case "validHeaderValue": signature = ([.string], .bool)
        default: return nil
        }
        return GoNativeFunction(
            symbol: "$http.\(member)", goName: "http.\(member)",
            parameters: signature.parameters, results: [signature.result])
    }

    /// The natives of `net/url`. The second operand of the escaping
    /// functions is the part of the URL the string belongs to.
    static func urlNativeFunction(_ member: String) -> GoNativeFunction? {
        let results: [GoType]
        var parameters: [GoType] = [.string, .int]
        switch member {
        // The text, what was wrong with it, and the kind of error: 0 for
        // none, 1 for a malformed escape, 2 for a byte no host has.
        case "unescape": results = [.string, .string, .int]
        case "escape": results = [.string]
        case "validEncoded": results = [.bool]
        case "hasControlByte": (parameters, results) = ([.string], [.bool])
        default: return nil
        }
        return GoNativeFunction(
            symbol: "$url.\(member)", goName: "url.\(member)",
            parameters: parameters, results: results)
    }

    static let httpNativeCallNames: Set<String> = [
        "$http.CanonicalHeaderKey", "$http.DetectContentType", "$http.lineEnd",
        "$http.formatTime", "$http.remoteAddr", "$http.validToken", "$http.validHeaderValue",
        "$url.unescape", "$url.escape", "$url.validEncoded", "$url.hasControlByte",
    ]
}
