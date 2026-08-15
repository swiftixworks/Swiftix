/// Fetching bytes: the network seam of the package manager.
///
/// Repositories are reached with the core's own socket syscalls — resolver, TCP
/// connect, send, recv — so a repository host is an ordinary node in the emulated
/// topology. Nothing platform-specific appears here; on a real network the
/// consumer's bridge carries the same traffic.
///
/// Two schemes are supported. `http://` is HTTP/1.0 with `Connection: close`,
/// which is what the built-in `httpd` speaks and all a static file repository
/// needs. `file:///` reads straight from the VFS, which makes a local directory a
/// first-class repository (handy for air-gapped hosts and for tests). `https://`
/// is deliberately rejected with a clear message rather than silently downgraded:
/// TLS is not part of the pure-Swift core, and integrity is instead guaranteed by
/// the SHA-256 recorded in the index.

import Swiftix

enum PackageTransport {

    /// Fetch `url`, following a bounded number of redirects. Returns the body on
    /// HTTP 200; any other status is an error carrying the code.
    static func fetch(
        _ context: ProcessContext,
        url: String,
        maximumBytes: Int
    ) async throws -> [UInt8] {
        var current = url
        for _ in 0...PackageLimits.maximumRedirects {
            if let path = PackageURL.parseFile(current) {
                guard let bytes = try PackageStore.read(context, path, maximumBytes: maximumBytes) else {
                    throw PackageError.httpStatus(url: current, status: 404)
                }
                return bytes
            }
            guard PackageURL.parseHTTP(current) != nil else {
                throw PackageError.unsupportedURLScheme(url: current)
            }
            let response = try await get(context, url: current, maximumBytes: maximumBytes)
            switch response.status {
            case 200:
                return response.body
            case 301, 302, 303, 307, 308:
                guard let location = response.location else {
                    throw PackageError.httpStatus(url: current, status: response.status)
                }
                current = resolveRedirect(from: current, location: location)
            default:
                throw PackageError.httpStatus(url: current, status: response.status)
            }
        }
        throw PackageError.tooManyRedirects(url: url)
    }

    /// Whether a URL can be fetched without touching the network — used to keep
    /// `update` output honest about which sources were read locally.
    static func isLocal(_ url: String) -> Bool {
        PackageURL.parseFile(url) != nil
    }

    // MARK: - HTTP

    private struct Response {
        let status: Int
        let location: String?
        let body: [UInt8]
    }

    private static func get(
        _ context: ProcessContext,
        url: String,
        maximumBytes: Int
    ) async throws -> Response {
        guard let target = PackageURL.parseHTTP(url) else {
            throw PackageError.malformedURL(url: url)
        }
        guard let address = await context.resolve(target.host) else {
            throw PackageError.unresolvableHost(host: target.host)
        }
        guard let socket = context.tcpSocket() else {
            throw PackageError.connectionFailed(host: target.host, port: target.port)
        }
        do {
            try await context.tcpConnect(socket, to: address, port: target.port)
        } catch {
            context.tcpClose(socket)
            throw PackageError.connectionFailed(host: target.host, port: target.port)
        }

        let request =
            "GET \(target.path) HTTP/1.0\r\n"
            + "Host: \(target.host)\r\n"
            + "User-Agent: pkg/1.0 (Swiftix)\r\n"
            + "Accept: */*\r\n"
            + "Connection: close\r\n\r\n"
        _ = context.tcpSend(socket, Array(request.utf8))

        // Headers plus body, bounded: a repository that streams forever is cut
        // off instead of consuming the host.
        let ceiling = maximumBytes + (16 << 10)
        var response: [UInt8] = []
        while response.count <= ceiling {
            guard let chunk = try? await context.tcpRecv(socket), !chunk.isEmpty else { break }
            response.append(contentsOf: chunk)
        }
        context.tcpClose(socket)
        guard response.count <= ceiling else {
            throw PackageError.responseTooLarge(url: url, limit: maximumBytes)
        }

        guard let split = headerBodySplit(response) else {
            throw PackageError.malformedURL(url: url)
        }
        let headerText = String(decoding: response[0..<split.headerEnd], as: UTF8.self)
        let lines = headerText.split(separator: "\n", omittingEmptySubsequences: true)
            .map { PackageText.trim(String($0)) }
        guard let statusLine = lines.first, let status = parseStatus(statusLine) else {
            throw PackageError.malformedURL(url: url)
        }
        var location: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = PackageText.trim(String(line[line.startIndex..<colon])).lowercased()
            if name == "location" {
                location = PackageText.trim(String(line[line.index(after: colon)...]))
            }
        }
        let body = Array(response[split.bodyStart...])
        guard body.count <= maximumBytes else {
            throw PackageError.responseTooLarge(url: url, limit: maximumBytes)
        }
        return Response(status: status, location: location, body: body)
    }

    /// `HTTP/1.1 200 OK` → 200.
    private static func parseStatus(_ line: String) -> Int? {
        let fields = PackageText.whitespaceSeparated(line)
        guard fields.count >= 2, fields[0].hasPrefix("HTTP/"), let code = Int(fields[1]),
            (100...599).contains(code)
        else { return nil }
        return code
    }

    /// Turn a `Location` header into an absolute URL: absolute values are used as
    /// they are, root-relative and relative ones are resolved against the request.
    private static func resolveRedirect(from url: String, location: String) -> String {
        if PackageURL.isSupported(location) { return location }
        guard let target = PackageURL.parseHTTP(url) else { return location }
        let authority = target.port == 80 ? target.host : "\(target.host):\(target.port)"
        if location.hasPrefix("/") { return "http://\(authority)\(location)" }
        let base = PackagePath.parent(of: target.path)
        return "http://\(authority)\(PackagePath.join(base, location))"
    }

    /// Index of the CRLFCRLF header terminator (also tolerating bare LFLF, which
    /// hand-written servers emit).
    private static func headerBodySplit(_ response: [UInt8]) -> (headerEnd: Int, bodyStart: Int)? {
        let crlf: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        if response.count >= crlf.count {
            for start in 0...(response.count - crlf.count)
            where Array(response[start..<(start + crlf.count)]) == crlf {
                return (start, start + crlf.count)
            }
        }
        let lf: [UInt8] = [0x0A, 0x0A]
        if response.count >= lf.count {
            for start in 0...(response.count - lf.count)
            where Array(response[start..<(start + lf.count)]) == lf {
                return (start, start + lf.count)
            }
        }
        return nil
    }
}
