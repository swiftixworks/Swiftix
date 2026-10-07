/// A small HTTP/1.1 helper: request parsing (request line + headers), response
/// building, keep-alive handling, and content-type guessing — enough for a
/// user-space `httpd` to serve files out of the VFS — plus the client half
/// (`curl`/`wget`): response-head parsing and chunked-body decoding. Still not a
/// full implementation (no compression, no request bodies on the server), but
/// it shows an application protocol built entirely on the TCP syscalls, as an
/// ordinary program.
///
/// Standard library only — no Foundation — so byte scanning is done by hand.
/// Kept `internal`; consumers writing their own server compose `Programs.serveTCP`
/// with their own parsing.
enum HTTP {

    /// A parsed request: method, path, lower-cased header map, and whether the
    /// connection should be kept alive (HTTP/1.1 unless `Connection: close`;
    /// HTTP/1.0 only with `Connection: keep-alive`).
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let keepAlive: Bool
    }

    /// Index just past the blank line ending the headers (`\r\n\r\n` or `\n\n`),
    /// or `nil` if the header block is not yet complete. Used to know when a whole
    /// request has been received off the socket.
    static func endOfHeaders(_ bytes: [UInt8]) -> Int? {
        if let i = firstIndex(of: [13, 10, 13, 10], in: bytes) { return i + 4 }
        if let i = firstIndex(of: [10, 10], in: bytes) { return i + 2 }
        return nil
    }

    /// Split a header block into lines on LF, dropping each line's trailing CR
    /// and any empty lines. Done on bytes, not `Character`s: Swift treats CRLF
    /// as a single grapheme, so splitting a `String` on "\n" never splits a
    /// CRLF-terminated block.
    static func lines(_ bytes: [UInt8]) -> [String] {
        bytes.split(separator: 10, omittingEmptySubsequences: true).compactMap { line in
            let trimmed = line.last == 13 ? line.dropLast() : line
            return trimmed.isEmpty ? nil : String(decoding: trimmed, as: UTF8.self)
        }
    }

    /// Parse a complete request (headers must be terminated). Returns `nil` if the
    /// header block is incomplete or the request line is malformed.
    static func parseRequest(_ bytes: [UInt8]) -> Request? {
        guard let headerEnd = endOfHeaders(bytes) else { return nil }
        let lines = Self.lines(Array(bytes[0..<headerEnd]))
        guard let requestLine = lines.first else { return nil }
        let fields = requestLine.split(separator: " ").map(String.init)
        guard fields.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            let value = trimmed(String(line[line.index(after: colon)...]))
            headers[name] = value
        }

        let version = fields.count >= 3 ? fields[2] : "HTTP/1.0"
        let connection = headers["connection"]?.lowercased()
        let keepAlive = version.contains("1.1") ? (connection != "close") : (connection == "keep-alive")
        return Request(method: fields[0], path: fields[1], headers: headers, keepAlive: keepAlive)
    }

    /// Build a complete HTTP/1.1 response (status line + headers + body).
    /// `Content-Length` always describes `body`; pass `includeBody: false` for a
    /// `HEAD` reply, which carries the same headers and no body bytes.
    static func response(status: Int,
                         reason: String,
                         body: [UInt8],
                         contentType: String = "text/plain",
                         keepAlive: Bool = false,
                         extraHeaders: [(name: String, value: String)] = [],
                         includeBody: Bool = true) -> [UInt8] {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        for header in extraHeaders {
            head += "\(header.name): \(header.value)\r\n"
        }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        head += "\r\n"
        return Array(head.utf8) + (includeBody ? body : [])
    }

    /// Guess a content type from a path's extension (small common set).
    static func contentType(forPath path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        guard name.contains(".") else { return "application/octet-stream" }
        let ext = name.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        switch ext {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "txt", "md", "log", "conf": return "text/plain"
        case "xml": return "application/xml"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Responses (client side)

    /// A parsed response head: status line and headers in wire order.
    struct ResponseHead: Equatable {
        let statusLine: String
        let status: Int
        let headers: [(name: String, value: String)]

        /// First value of header `name` (case-insensitive).
        func header(_ name: String) -> String? {
            let wanted = name.lowercased()
            return headers.first { $0.name.lowercased() == wanted }?.value
        }

        static func == (lhs: ResponseHead, rhs: ResponseHead) -> Bool {
            lhs.statusLine == rhs.statusLine && lhs.status == rhs.status
                && lhs.headers.map(\.name) == rhs.headers.map(\.name)
                && lhs.headers.map(\.value) == rhs.headers.map(\.value)
        }
    }

    /// Parse a complete response head (`bytes` up to and including the blank
    /// line). Returns `nil` when the status line is not `HTTP/x.y NNN …`.
    static func parseResponseHead(_ bytes: [UInt8]) -> ResponseHead? {
        let lines = Self.lines(bytes)
        guard let statusLine = lines.first else { return nil }
        let fields = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard fields.count >= 2, fields[0].hasPrefix("HTTP/"), let status = Int(fields[1]) else { return nil }
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((String(line[line.startIndex..<colon]),
                            trimmed(String(line[line.index(after: colon)...]))))
        }
        return ResponseHead(statusLine: statusLine, status: status, headers: headers)
    }

    /// Decode a `Transfer-Encoding: chunked` body. `complete` is false until the
    /// terminating zero-length chunk has arrived, so a caller reading off a
    /// socket knows whether to keep receiving. Trailers are ignored.
    static func decodeChunked(_ bytes: [UInt8]) -> (body: [UInt8], complete: Bool) {
        var body: [UInt8] = []
        var offset = 0
        while true {
            // Chunk-size line: hex digits, optional `;extension`, CRLF.
            guard let lineEnd = firstIndex(of: [13, 10], in: Array(bytes[offset...])) else { return (body, false) }
            let sizeText = String(decoding: bytes[offset..<(offset + lineEnd)], as: UTF8.self)
            let hex = sizeText.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard let size = Int(trimmed(String(hex)), radix: 16), size >= 0 else { return (body, true) }
            offset += lineEnd + 2
            if size == 0 { return (body, true) }
            guard offset + size <= bytes.count else {
                body.append(contentsOf: bytes[offset...])
                return (body, false)
            }
            body.append(contentsOf: bytes[offset..<(offset + size)])
            offset += size + 2   // chunk data + its trailing CRLF
            guard offset <= bytes.count else { return (body, false) }
        }
    }

    // MARK: - Byte helpers (no Foundation)

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return start
        }
        return nil
    }

    private static func trimmed(_ s: String) -> String {
        func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" }
        var chars = Array(s)
        while let f = chars.first, isSpace(f) { chars.removeFirst() }
        while let l = chars.last, isSpace(l) { chars.removeLast() }
        return String(chars)
    }
}
