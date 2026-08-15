/// A small HTTP/1.1 helper: request parsing (request line + headers), response
/// building, keep-alive handling, and content-type guessing — enough for a
/// user-space `httpd` to serve files out of the VFS. Still not a full server
/// (GET-focused, no chunked/compressed bodies), but it shows an application
/// protocol built entirely on the TCP syscalls, as an ordinary program.
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

    /// Parse a complete request (headers must be terminated). Returns `nil` if the
    /// header block is incomplete or the request line is malformed.
    static func parseRequest(_ bytes: [UInt8]) -> Request? {
        guard let headerEnd = endOfHeaders(bytes) else { return nil }
        let headerText = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
        let lines = headerText
            .split(whereSeparator: { $0 == "\n" })
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
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
    static func response(status: Int,
                         reason: String,
                         body: [UInt8],
                         contentType: String = "text/plain",
                         keepAlive: Bool = false) -> [UInt8] {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        head += "\r\n"
        return Array(head.utf8) + body
    }

    /// Guess a content type from a path's extension (small common set).
    static func contentType(forPath path: String) -> String {
        let ext = path.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        switch ext {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "txt": return "text/plain"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
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
