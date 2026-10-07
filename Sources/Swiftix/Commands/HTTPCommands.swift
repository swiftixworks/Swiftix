/// HTTP built-ins: the `curl` and `wget` clients and the `httpd` static server.
///
/// The two clients share one exchange function (`httpExchange`): resolve the
/// host, connect with a deadline, send one HTTP/1.1 request with
/// `Connection: close`, and read the reply framed by `Content-Length`,
/// chunked encoding, or end-of-stream. Failures are values (`HTTPFailure`), so
/// each front-end maps them to its own messages and exit codes — `curl`'s are
/// the real tool's numbers (6 resolve, 7 connect, 22 HTTP error with `-f`,
/// 28 timeout, …).
///
/// Only plain `http://` is spoken: the core has no TLS, and an `https://` URL is
/// refused with an explicit message rather than a usage dump.
///
/// Concurrency: `async` programs on the kernel's serial executor. Every wait is
/// a parked syscall; timeouts are logical-time deadlines, never wall-clock.
extension BuiltinCommands {

    static func httpCommands() -> [Command] {
        [
            // curl [options] <url>… — fetch http:// URLs over TCP.
            Command(name: "curl", summary: "transfer an http:// URL", category: .network, asyncRun: { ctx, argv in
                await runCurl(ctx, argv)
            }),

            // wget [-q] [-O file] <url> — fetch an http:// URL and save the body to
            // a file (default: the last path component, or `index.html`); `-O -`
            // writes it to stdout.
            Command(name: "wget", summary: "download an http:// URL to a file", category: .network, asyncRun: { ctx, argv in
                await runWget(ctx, argv)
            }),

            // httpd [-p port] [port] [docroot] — a static-file HTTP server on
            // `serveTCP`: it serves files straight out of the VFS.
            Command(name: "httpd", summary: "serve files over HTTP", category: .network, asyncRun: { ctx, argv in
                await runHTTPD(ctx, argv)
            }),
        ]
    }

    // MARK: - URLs

    struct HTTPURL: Equatable {
        var host: String
        var port: UInt16
        /// Path plus query, always starting with `/`.
        var path: String

        /// The `Host:` header value (port included only when it is not 80).
        var authority: String { port == 80 ? host : "\(host):\(port)" }

        var text: String { "http://\(authority)\(path)" }

        /// The path without its query string.
        var pathOnly: String {
            String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        }
    }

    enum HTTPURLError: Error, Equatable {
        /// A scheme other than `http` (carries the scheme, lower-cased).
        case unsupportedScheme(String)
        case malformed
    }

    /// Parse `[http://]host[:port][/path]`. `host` may be a name (resolved
    /// later) or an IPv4 literal. Defaults: port 80, path `/`. A fragment is
    /// dropped; userinfo is not supported.
    static func parseURL(_ string: String) -> Result<HTTPURL, HTTPURLError> {
        var rest = Substring(string)
        if let separator = rest.firstRange(of: "://") {
            let scheme = rest[rest.startIndex..<separator.lowerBound].lowercased()
            guard scheme == "http" else { return .failure(.unsupportedScheme(scheme)) }
            rest = rest[separator.upperBound...]
        }
        if let fragment = rest.firstIndex(of: "#") { rest = rest[rest.startIndex..<fragment] }
        // Split authority from path at the first "/" or "?".
        let authority: Substring
        var path: String
        if let boundary = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) {
            authority = rest[rest.startIndex..<boundary]
            path = String(rest[boundary...])
            if path.hasPrefix("?") { path = "/" + path }
        } else {
            authority = rest
            path = "/"
        }
        guard !authority.contains("@"), !authority.contains(" ") else { return .failure(.malformed) }
        // Split host from optional ":port".
        let host: String
        var port: UInt16 = 80
        if let colon = authority.firstIndex(of: ":") {
            host = String(authority[authority.startIndex..<colon])
            guard let parsed = UInt16(authority[authority.index(after: colon)...]), parsed != 0 else {
                return .failure(.malformed)
            }
            port = parsed
        } else {
            host = String(authority)
        }
        guard !host.isEmpty else { return .failure(.malformed) }
        return .success(HTTPURL(host: host, port: port, path: path))
    }

    /// Resolve a `Location:` value against the URL that produced it.
    static func resolveRedirect(_ location: String, from base: HTTPURL) -> Result<HTTPURL, HTTPURLError> {
        if location.firstRange(of: "://") != nil { return parseURL(location) }
        if location.hasPrefix("//") { return parseURL("http:" + location) }
        var target = base
        if location.hasPrefix("/") {
            target.path = location
        } else {
            // Relative reference: replace the last segment of the base path.
            let directory = base.pathOnly.split(separator: "/", omittingEmptySubsequences: false).dropLast()
            target.path = directory.joined(separator: "/") + "/" + location
        }
        if let fragment = target.path.firstIndex(of: "#") {
            target.path = String(target.path[target.path.startIndex..<fragment])
        }
        return .success(target)
    }

    // MARK: - The exchange

    struct HTTPRequest {
        var method: String
        var url: HTTPURL
        /// Sent after `Host:`, in order.
        var headers: [(name: String, value: String)] = []
        var body: [UInt8]?
    }

    struct HTTPReply {
        var head: HTTP.ResponseHead
        /// The response head exactly as received, blank line included.
        var headBytes: [UInt8]
        var body: [UInt8]
        var remote: IPv4Address
    }

    enum HTTPFailure: Error, Equatable {
        case resolve(String)
        case connectRefused
        case connectUnreachable
        case connectTimeout
        /// The transfer deadline passed; carries the body bytes received so far.
        case timeout(received: Int)
        case emptyReply
        case malformedReply
        case reset
        case interrupted
    }

    /// Events `curl -v` narrates.
    enum HTTPTraceEvent {
        case connecting(IPv4Address, UInt16)
        case connected(host: String, address: IPv4Address, port: UInt16)
        case requestHead(String)
        case responseHead([UInt8])
        case closed
    }

    /// The request head `httpExchange` sends, as text.
    static func requestHead(_ request: HTTPRequest) -> String {
        var head = "\(request.method) \(request.url.path) HTTP/1.1\r\n"
        head += "Host: \(request.url.authority)\r\n"
        for header in request.headers {
            head += "\(header.name): \(header.value)\r\n"
        }
        if let body = request.body {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return head
    }

    /// Run one request/response over a fresh connection.
    ///
    /// - Parameters:
    ///   - deadline: absolute logical time (`ctx.logicalSeconds`) by which the
    ///     whole exchange must finish, or `nil` for no limit.
    ///   - connectTimeout: bound on the handshake alone.
    static func httpExchange(_ ctx: ProcessContext,
                             _ request: HTTPRequest,
                             deadline: Double? = nil,
                             connectTimeout: Double? = nil,
                             trace: ((HTTPTraceEvent) -> Void)? = nil) async -> Result<HTTPReply, HTTPFailure> {
        guard let address = await ctx.resolve(request.url.host) else {
            return .failure(.resolve(request.url.host))
        }
        guard let fd = ctx.tcpSocket() else { return .failure(.connectUnreachable) }
        defer { ctx.tcpClose(fd) }

        func remaining() -> Double? { deadline.map { $0 - ctx.logicalSeconds } }

        trace?(.connecting(address, request.url.port))
        var handshakeLimit = remaining()
        if let connectTimeout { handshakeLimit = min(handshakeLimit ?? connectTimeout, connectTimeout) }
        do {
            switch try await ctx.tcpConnect(fd, to: address, port: request.url.port, timeout: handshakeLimit) {
            case .connected: break
            case .refused: return .failure(.connectRefused)
            case .unreachable: return .failure(.connectUnreachable)
            case .timedOut: return .failure(.connectTimeout)
            }
        } catch {
            return .failure(.interrupted)
        }
        trace?(.connected(host: request.url.host, address: address, port: request.url.port))

        let head = requestHead(request)
        trace?(.requestHead(head))
        _ = ctx.tcpSend(fd, Array(head.utf8) + (request.body ?? []))

        var buffer: [UInt8] = []
        var headEnd: Int?
        var parsedHead: HTTP.ResponseHead?
        var sawEnd = false

        /// Body framing once the head is known: bytes still expected, or `nil`
        /// for "until the peer closes".
        func bodyIsComplete() -> Bool {
            guard let head = parsedHead, let headEnd else { return false }
            if request.method == "HEAD" || head.status == 204 || head.status == 304 || (100..<200).contains(head.status) {
                return true
            }
            let body = Array(buffer[headEnd...])
            if head.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
                return HTTP.decodeChunked(body).complete
            }
            if let length = head.header("Content-Length").flatMap({ Int($0) }) {
                return body.count >= length
            }
            return false
        }

        while !sawEnd && !bodyIsComplete() {
            do {
                let left = remaining()
                if let left, left <= 0 {
                    return .failure(.timeout(received: max(0, buffer.count - (headEnd ?? buffer.count))))
                }
                guard try await ctx.waitReadable(fd, timeout: left) else {
                    return .failure(.timeout(received: max(0, buffer.count - (headEnd ?? buffer.count))))
                }
                let bytes = try await ctx.tcpRecv(fd)
                if bytes.isEmpty {
                    sawEnd = true
                } else {
                    buffer.append(contentsOf: bytes)
                }
            } catch SyscallError.connectionReset {
                if parsedHead == nil { return .failure(.reset) }
                sawEnd = true
            } catch {
                return .failure(.interrupted)
            }
            if parsedHead == nil, let end = HTTP.endOfHeaders(buffer) {
                guard let head = HTTP.parseResponseHead(Array(buffer[0..<end])) else {
                    return .failure(.malformedReply)
                }
                headEnd = end
                parsedHead = head
                trace?(.responseHead(Array(buffer[0..<end])))
            }
        }
        trace?(.closed)

        guard let head = parsedHead, let headEnd else {
            return .failure(buffer.isEmpty ? .emptyReply : .malformedReply)
        }
        var body = Array(buffer[headEnd...])
        if request.method == "HEAD" {
            body = []
        } else if head.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
            body = HTTP.decodeChunked(body).body
        } else if let length = head.header("Content-Length").flatMap({ Int($0) }), length >= 0, body.count > length {
            body = Array(body[0..<length])
        }
        return .success(HTTPReply(head: head, headBytes: Array(buffer[0..<headEnd]), body: body, remote: address))
    }

    // MARK: - curl

    private static let curlUsage = networkSynopsis("curl")

    struct CurlOptions {
        var headOnly = false
        var includeHeaders = false
        var silent = false
        var showError = false
        var failOnError = false
        var followRedirects = false
        var verbose = false
        var output: String?
        var remoteName = false
        var method: String?
        var data: [String] = []
        var headers: [String] = []
        var userAgent = "curl/swiftix"
        var writeOut: String?
        var maxTime: Double?
        var connectTimeout: Double?
        var maxRedirects = 50
        var urls: [String] = []
    }

    /// Expand a `-w` format: `%{variable}` and the `\n` `\t` `\r` `\\` escapes.
    /// Unknown variables expand to nothing, as in curl.
    static func expandWriteOut(_ format: String, variables: [String: String]) -> String {
        var output = ""
        var characters = Array(format)[...]
        while let character = characters.first {
            characters = characters.dropFirst()
            if character == "\\", let next = characters.first {
                characters = characters.dropFirst()
                switch next {
                case "n": output.append("\n")
                case "t": output.append("\t")
                case "r": output.append("\r")
                default: output.append(next)
                }
            } else if character == "%", characters.first == "{",
                      let close = characters.firstIndex(of: "}") {
                let name = String(characters[characters.index(after: characters.startIndex)..<close])
                output += variables[name] ?? ""
                characters = characters[characters.index(after: close)...]
            } else if character == "%", characters.first == "%" {
                characters = characters.dropFirst()
                output.append("%")
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static func parseCurlOptions(_ ctx: ProcessContext, _ argv: [String]) -> CurlOptions? {
        let long: [String: NetworkOptions.Long] = [
            "head": .init("I"), "include": .init("i"), "silent": .init("s"),
            "show-error": .init("S"), "fail": .init("f"), "location": .init("L"),
            "verbose": .init("v"), "output": .init("o", value: true), "remote-name": .init("O"),
            "request": .init("X", value: true), "data": .init("d", value: true),
            "data-raw": .init("data-raw", value: true), "data-binary": .init("d", value: true),
            "data-ascii": .init("d", value: true),
            "header": .init("H", value: true), "user-agent": .init("A", value: true),
            "write-out": .init("w", value: true), "max-time": .init("m", value: true),
            "connect-timeout": .init("connect-timeout", value: true),
            "max-redirs": .init("max-redirs", value: true), "url": .init("url", value: true),
            "no-progress-meter": .init("ignored"), "http1.1": .init("ignored"), "http1.0": .init("ignored"),
            "ipv4": .init("ignored"), "no-buffer": .init("ignored"), "compressed": .init("ignored"),
        ]
        guard let items = ctx.scanOptions(argv, command: "curl", usage: curlUsage,
                                          flags: "IisSfLvO4N#", valued: "oXdHAwm", long: long) else { return nil }
        var options = CurlOptions()
        func bad(_ what: String, _ value: String) -> CurlOptions? {
            ctx.invalidArgument("curl", "invalid \(what): '\(value)'", usage: curlUsage)
            return nil
        }
        for item in items {
            switch item {
            case .operand(let url), .option("url", let url?):
                options.urls.append(url)
            case .option("I", _): options.headOnly = true
            case .option("i", _): options.includeHeaders = true
            case .option("s", _): options.silent = true
            case .option("S", _): options.showError = true
            case .option("f", _): options.failOnError = true
            case .option("L", _): options.followRedirects = true
            case .option("v", _): options.verbose = true
            case .option("O", _): options.remoteName = true
            case .option("o", let value?): options.output = value
            case .option("X", let value?): options.method = value.uppercased()
            case .option("H", let value?): options.headers.append(value)
            case .option("A", let value?): options.userAgent = value
            case .option("w", let value?): options.writeOut = value
            case .option("data-raw", let value?): options.data.append(value)
            case .option("d", let value?):
                if value.hasPrefix("@") {
                    let path = String(value.dropFirst())
                    guard let text = readTextFile(ctx, path) else {
                        ctx.fail("curl: (26) Failed to open/read local data from file \(path)", code: 26)
                        return nil
                    }
                    // Like curl's -d @file: newlines are stripped.
                    options.data.append(String(decoding: text.utf8.filter { $0 != 10 && $0 != 13 }, as: UTF8.self))
                } else {
                    options.data.append(value)
                }
            case .option("m", let value?):
                guard let seconds = Double(value), seconds > 0 else { return bad("max time", value) }
                options.maxTime = seconds
            case .option("connect-timeout", let value?):
                guard let seconds = Double(value), seconds > 0 else { return bad("connect timeout", value) }
                options.connectTimeout = seconds
            case .option("max-redirs", let value?):
                guard let limit = Int(value), limit >= 0 else { return bad("redirect limit", value) }
                options.maxRedirects = limit
            case .option:
                break   // accepted, nothing to do (-4, -N, -#, --compressed, …)
            }
        }
        return options
    }

    /// Assemble the request headers: curl's defaults, each replaceable by a
    /// `-H 'Name: value'` of the same name and removable with `-H 'Name:'`.
    static func curlHeaders(_ options: CurlOptions, hasBody: Bool) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = [
            ("User-Agent", options.userAgent),
            ("Accept", "*/*"),
        ]
        if hasBody { headers.append(("Content-Type", "application/x-www-form-urlencoded")) }
        for raw in options.headers {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let name = String(raw[raw.startIndex..<colon])
            let value = String(raw[raw.index(after: colon)...].drop { $0 == " " || $0 == "\t" })
            headers.removeAll { $0.name.lowercased() == name.lowercased() }
            if !value.isEmpty { headers.append((name, value)) }
        }
        return headers
    }

    private static func runCurl(_ ctx: ProcessContext, _ argv: [String]) async {
        guard let options = parseCurlOptions(ctx, argv) else { return }
        guard !options.urls.isEmpty else {
            ctx.error("curl: (2) no URL specified")
            ctx.usage("curl", curlUsage)
            return
        }
        var status: Int32 = 0
        for url in options.urls {
            let code = await curlTransfer(ctx, options, url)
            if code != 0 { status = code }
        }
        ctx.exit(status)
    }

    /// Perform one URL's transfer and return curl's exit code for it.
    private static func curlTransfer(_ ctx: ProcessContext, _ options: CurlOptions, _ urlText: String) async -> Int32 {
        func report(_ code: Int32, _ message: String) -> Int32 {
            if !options.silent || options.showError { ctx.error("curl: (\(code)) \(message)") }
            return code
        }
        func note(_ line: String) {
            if options.verbose { ctx.error(line) }
        }

        var url: HTTPURL
        switch parseURL(urlText) {
        case .success(let parsed):
            url = parsed
        case .failure(.unsupportedScheme(let scheme)):
            let reason = scheme == "https" ? ": this build has no TLS" : ""
            return report(1, "Protocol \"\(scheme)\" not supported\(reason)")
        case .failure(.malformed):
            return report(3, "URL rejected: Malformed input to a URL function")
        }

        // Where the body goes. Decided before the transfer so a bad `-O` fails early.
        var outputPath = options.output
        if options.remoteName {
            let name = url.pathOnly.split(separator: "/").last.map(String.init) ?? ""
            guard !name.isEmpty else { return report(23, "Remote file name has no length") }
            outputPath = name
        }

        let body: [UInt8]? = options.data.isEmpty ? nil : Array(options.data.joined(separator: "&").utf8)
        var method = options.method ?? (options.headOnly ? "HEAD" : (body != nil ? "POST" : "GET"))
        var requestBody = options.headOnly ? nil : body
        let start = ctx.logicalSeconds
        let deadline = options.maxTime.map { start + $0 }
        var redirects = 0
        var collectedHeads: [UInt8] = []
        var reply: HTTPReply

        while true {
            let request = HTTPRequest(method: method, url: url,
                                      headers: curlHeaders(options, hasBody: requestBody != nil),
                                      body: requestBody)
            let result = await httpExchange(ctx, request, deadline: deadline,
                                            connectTimeout: options.connectTimeout) { event in
                switch event {
                case let .connecting(address, port):
                    note("*   Trying \(address):\(port)...")
                case let .connected(host, address, port):
                    note("* Connected to \(host) (\(address)) port \(port)")
                case .requestHead(let head):
                    for line in HTTP.lines(Array(head.utf8)) { note("> \(line)") }
                    note(">")
                case .responseHead(let bytes):
                    for line in HTTP.lines(bytes) { note("< \(line)") }
                    note("<")
                case .closed:
                    note("* Closing connection")
                }
            }
            let milliseconds = Int(((ctx.logicalSeconds - start) * 1000).rounded())
            switch result {
            case .success(let received):
                reply = received
            case .failure(.resolve(let host)):
                return report(6, "Could not resolve host: \(host)")
            case .failure(.connectRefused):
                return report(7, "Failed to connect to \(url.host) port \(url.port): Connection refused")
            case .failure(.connectUnreachable):
                return report(7, "Failed to connect to \(url.host) port \(url.port): Couldn't connect to server")
            case .failure(.connectTimeout):
                return report(28, "Connection timed out after \(milliseconds) milliseconds")
            case .failure(.timeout(let received)):
                return report(28, "Operation timed out after \(milliseconds) milliseconds with \(received) bytes received")
            case .failure(.emptyReply):
                return report(52, "Empty reply from server")
            case .failure(.malformedReply):
                return report(1, "Received HTTP/0.9 when not allowed")
            case .failure(.reset):
                return report(56, "Recv failure: Connection reset by peer")
            case .failure(.interrupted):
                return 130
            }

            let status = reply.head.status
            guard options.followRedirects, (300..<400).contains(status), status != 304,
                  let location = reply.head.header("Location") else { break }
            guard redirects < options.maxRedirects else {
                return report(47, "Maximum (\(options.maxRedirects)) redirects followed")
            }
            switch resolveRedirect(location, from: url) {
            case .success(let next):
                url = next
            case .failure(.unsupportedScheme(let scheme)):
                let reason = scheme == "https" ? ": this build has no TLS" : ""
                return report(1, "Protocol \"\(scheme)\" not supported\(reason)")
            case .failure(.malformed):
                return report(3, "URL rejected: Malformed input to a URL function")
            }
            redirects += 1
            collectedHeads.append(contentsOf: reply.headBytes)
            // 303 always becomes GET; 301/302 do for POST (what browsers and curl do);
            // 307/308 repeat the request unchanged.
            if status == 303 || ((status == 301 || status == 302) && method == "POST") {
                if method != "HEAD" { method = "GET" }
                requestBody = nil
            }
            note("* Issue another request to this URL: '\(url.text)'")
        }

        var exitCode: Int32 = 0
        if options.failOnError, reply.head.status >= 400 {
            exitCode = report(22, "The requested URL returned error: \(reply.head.status)")
        } else {
            var output: [UInt8] = []
            if options.includeHeaders || options.headOnly {
                output.append(contentsOf: collectedHeads)
                output.append(contentsOf: reply.headBytes)
            }
            output.append(contentsOf: reply.body)
            if let outputPath, outputPath != "-" {
                guard let file = ctx.open(outputPath, create: true, truncate: true) else {
                    return report(23, "Failure writing output to destination")
                }
                ctx.write(file, output)
                ctx.close(file)
            } else {
                ctx.write(1, output)
            }
        }

        if let format = options.writeOut {
            let variables: [String: String] = [
                "http_code": String(reply.head.status),
                "response_code": String(reply.head.status),
                "size_download": String(reply.body.count),
                "url_effective": url.text,
                "content_type": reply.head.header("Content-Type") ?? "",
                "num_redirects": String(redirects),
                "remote_ip": "\(reply.remote)",
                "remote_port": String(url.port),
                "time_total": fixedPoint(ctx.logicalSeconds - start, places: 6),
            ]
            ctx.print(expandWriteOut(format, variables: variables))
        }
        return exitCode
    }

    // MARK: - wget

    private static func runWget(_ ctx: ProcessContext, _ argv: [String]) async {
        let usage = networkSynopsis("wget")
        guard let items = ctx.scanOptions(argv, command: "wget", usage: usage,
                                          flags: "qv", valued: "OTt",
                                          long: ["quiet": .init("q"), "verbose": .init("v"),
                                                 "output-document": .init("O", value: true),
                                                 "timeout": .init("T", value: true),
                                                 "tries": .init("t", value: true)]) else { return }
        var output: String?
        var quiet = false
        var timeout: Double?
        var urls: [String] = []
        for item in items {
            switch item {
            case .operand(let url): urls.append(url)
            case .option("q", _): quiet = true
            case .option("O", let value?): output = value
            case .option("T", let value?):
                guard let seconds = Double(value), seconds > 0 else {
                    ctx.invalidArgument("wget", "invalid timeout: '\(value)'", usage: usage); return
                }
                timeout = seconds
            case .option: break   // -v / -t: accepted
            }
        }
        guard urls.count == 1 else { ctx.usage("wget", usage); return }
        func say(_ message: String) {
            if !quiet { ctx.error(message) }
        }

        var url: HTTPURL
        switch parseURL(urls[0]) {
        case .success(let parsed):
            url = parsed
        case .failure(.unsupportedScheme(let scheme)):
            let reason = scheme == "https" ? ": this build has no TLS" : ""
            ctx.fail("wget: Protocol \"\(scheme)\" not supported\(reason)", code: 1); return
        case .failure(.malformed):
            ctx.fail("wget: \(urls[0]): Invalid URL", code: 1); return
        }

        // Default output file: the URL's last path component, or index.html.
        let destination = output ?? {
            let component = url.pathOnly.split(separator: "/").last.map(String.init) ?? ""
            return component.isEmpty ? "index.html" : component
        }()

        let deadline = timeout.map { ctx.logicalSeconds + $0 }
        var redirects = 0
        var reply: HTTPReply
        while true {
            let request = HTTPRequest(method: "GET", url: url,
                                      headers: [("User-Agent", "Wget/swiftix"), ("Accept", "*/*")])
            switch await httpExchange(ctx, request, deadline: deadline) {
            case .success(let received):
                reply = received
            case .failure(.resolve(let host)):
                ctx.fail("wget: unable to resolve host address '\(host)'", code: 4); return
            case .failure(.connectRefused):
                ctx.fail("wget: failed to connect to \(url.authority): Connection refused", code: 4); return
            case .failure(.connectUnreachable):
                ctx.fail("wget: failed to connect to \(url.authority): No route to host", code: 4); return
            case .failure(.connectTimeout), .failure(.timeout):
                ctx.fail("wget: \(url.authority): Connection timed out", code: 4); return
            case .failure(.interrupted):
                return
            case .failure:
                ctx.fail("wget: \(url.authority): No data received", code: 4); return
            }
            guard (300..<400).contains(reply.head.status), reply.head.status != 304,
                  let location = reply.head.header("Location") else { break }
            guard redirects < 20 else {
                ctx.fail("wget: 20 redirections exceeded", code: 8); return
            }
            switch resolveRedirect(location, from: url) {
            case .success(let next):
                url = next
            case .failure(.unsupportedScheme(let scheme)):
                let reason = scheme == "https" ? ": this build has no TLS" : ""
                ctx.fail("wget: Protocol \"\(scheme)\" not supported\(reason)", code: 1); return
            case .failure(.malformed):
                ctx.fail("wget: \(location): Invalid URL", code: 1); return
            }
            redirects += 1
            say("wget: following redirect to \(url.text)")
        }

        guard reply.head.status < 400 else {
            ctx.fail("wget: server returned error: \(reply.head.statusLine)", code: 8); return
        }
        if destination == "-" {
            ctx.write(1, reply.body)
            ctx.exit(0)
            return
        }
        guard let outFD = ctx.open(destination, create: true, truncate: true) else {
            ctx.fail("wget: cannot write to \(destination)", code: 3); return
        }
        ctx.write(outFD, reply.body)
        ctx.close(outFD)
        say("wget: saved \(reply.body.count) bytes to \(destination)")
        ctx.exit(0)
    }

    // MARK: - httpd

    /// What `httpd` decided to do with one request path, before any I/O on the
    /// socket — pure, so the mapping is testable on its own.
    enum HTTPDTarget: Equatable {
        case file(String)
        /// A directory requested without its trailing slash.
        case redirect(String)
        case listing(directory: String, requestPath: String)
        case notFound
        case forbidden
    }

    /// Percent-decode a request path; `nil` for a malformed escape.
    static func percentDecode(_ text: String) -> String? {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8)[...]
        while let byte = iterator.first {
            iterator = iterator.dropFirst()
            guard byte == UInt8(ascii: "%") else { bytes.append(byte); continue }
            guard iterator.count >= 2,
                  let value = UInt8(String(decoding: iterator.prefix(2), as: UTF8.self), radix: 16) else { return nil }
            bytes.append(value)
            iterator = iterator.dropFirst(2)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Map a request target onto the document root. `..` segments are refused
    /// rather than resolved, so a request can never leave `docroot`.
    static func httpdTarget(_ ctx: ProcessContext, docroot: String, requestTarget: String) -> HTTPDTarget {
        let rawPath = String(requestTarget.split(maxSplits: 1, omittingEmptySubsequences: false,
                                                 whereSeparator: { $0 == "?" || $0 == "#" })[0])
        guard let path = percentDecode(rawPath), path.hasPrefix("/") else { return .forbidden }
        let segments = path.split(separator: "/").map(String.init)
        guard !segments.contains(".."), !path.utf8.contains(0) else { return .forbidden }
        let root = docroot == "/" ? "" : docroot
        let relative = segments.filter { $0 != "." }.joined(separator: "/")
        let local = relative.isEmpty ? (root.isEmpty ? "/" : root) : root + "/" + relative
        if ctx.listDirectory(local) != nil {
            guard path.hasSuffix("/") else { return .redirect(rawPath + "/") }
            let index = (local == "/" ? "" : local) + "/index.html"
            if ctx.stat(index) != nil, ctx.listDirectory(index) == nil { return .file(index) }
            return .listing(directory: local, requestPath: path)
        }
        return ctx.stat(local) != nil ? .file(local) : .notFound
    }

    static func escapeHTML(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// An HTML index of `directory`, entries sorted, directories suffixed `/`.
    static func directoryListing(_ ctx: ProcessContext, directory: String, requestPath: String) -> [UInt8] {
        let title = "Index of \(escapeHTML(requestPath))"
        var html = "<!DOCTYPE html>\n<html><head><title>\(title)</title></head>\n<body>\n<h1>\(title)</h1>\n<ul>\n"
        if requestPath != "/" { html += "<li><a href=\"../\">../</a></li>\n" }
        // `listDirectory` may already mark directories with a trailing slash.
        let names = (ctx.listDirectory(directory) ?? [])
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .sorted()
        for name in names {
            let child = (directory == "/" ? "" : directory) + "/" + name
            let display = escapeHTML(name + (ctx.listDirectory(child) != nil ? "/" : ""))
            html += "<li><a href=\"\(display)\">\(display)</a></li>\n"
        }
        html += "</ul>\n</body></html>\n"
        return Array(html.utf8)
    }

    private static func runHTTPD(_ ctx: ProcessContext, _ argv: [String]) async {
        let usage = networkSynopsis("httpd")
        guard let items = ctx.scanOptions(argv, command: "httpd", usage: usage, valued: "p",
                                          long: ["port": .init("p", value: true)]) else { return }
        var port: UInt16?
        var docroot: String?
        for item in items {
            switch item {
            case .option(_, let value):
                guard let parsed = UInt16(value ?? ""), parsed != 0 else {
                    ctx.invalidArgument("httpd", "invalid port: '\(value ?? "")'", usage: usage); return
                }
                port = parsed
            case .operand(let value):
                if port == nil, docroot == nil, let parsed = UInt16(value), parsed != 0 {
                    port = parsed
                } else if docroot == nil {
                    docroot = value
                } else {
                    ctx.usage("httpd", usage); return
                }
            }
        }
        var root = docroot ?? "/"
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        guard ctx.listDirectory(root) != nil else {
            ctx.fail("httpd: \(root): not a directory", code: 1); return
        }
        let listenPort = port ?? 80
        // Announce only once the socket is actually listening; a failed
        // bind (port in use) prints an error from serveTCP and exits.
        await Programs.serveTCP(ctx, port: listenPort, onListening: {
            ctx.print("httpd: serving \(root) on \(listenPort)\n")
        }) { conn, fd in
            var buffer: [UInt8] = []
            // One connection may carry several requests (keep-alive).
            while true {
                // Accumulate until a full header block has arrived.
                while HTTP.endOfHeaders(buffer) == nil {
                    guard let chunk = try? await conn.tcpRecv(fd), !chunk.isEmpty else { return }
                    buffer.append(contentsOf: chunk)
                }
                guard let request = HTTP.parseRequest(buffer) else {
                    _ = conn.tcpSend(fd, HTTP.response(status: 400, reason: "Bad Request",
                                                       body: Array("bad request\n".utf8)))
                    return
                }
                // Consume the request's header block; keep any pipelined bytes.
                buffer.removeFirst(HTTP.endOfHeaders(buffer)!)

                let isHead = request.method == "HEAD"
                guard isHead || request.method == "GET" else {
                    // A static server: anything else is refused, and the connection
                    // closed so an unread request body cannot be misparsed.
                    _ = conn.tcpSend(fd, HTTP.response(status: 405, reason: "Method Not Allowed",
                                                       body: Array("method not allowed\n".utf8),
                                                       extraHeaders: [("Allow", "GET, HEAD")]))
                    return
                }
                func send(_ status: Int, _ reason: String, _ body: [UInt8],
                          type: String = "text/plain",
                          extra: [(name: String, value: String)] = []) {
                    _ = conn.tcpSend(fd, HTTP.response(status: status, reason: reason, body: body,
                                                       contentType: type, keepAlive: request.keepAlive,
                                                       extraHeaders: extra, includeBody: !isHead))
                }
                switch httpdTarget(conn, docroot: root, requestTarget: request.path) {
                case .file(let path):
                    if let file = conn.open(path) {
                        let body = readFully(conn, file)
                        conn.close(file)
                        send(200, "OK", body, type: HTTP.contentType(forPath: path))
                    } else {
                        send(403, "Forbidden", Array("forbidden\n".utf8))
                    }
                case .redirect(let location):
                    send(301, "Moved Permanently", Array("moved to \(location)\n".utf8),
                         extra: [("Location", location)])
                case let .listing(directory, requestPath):
                    send(200, "OK", directoryListing(conn, directory: directory, requestPath: requestPath),
                         type: "text/html")
                case .notFound:
                    send(404, "Not Found", Array("not found\n".utf8))
                case .forbidden:
                    send(403, "Forbidden", Array("forbidden\n".utf8))
                }
                if !request.keepAlive { return }
            }
        }
    }
}
