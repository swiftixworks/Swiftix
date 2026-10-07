import Testing
@testable import Swiftix

/// `curl` and `wget` end to end over loopback: against the built-in `httpd`
/// for static content, and against a small scripted server for methods,
/// headers, bodies, redirects, chunking and timeouts.
@Suite("curl and wget")
struct HTTPClientTests {

    /// Loopback host with `httpd` serving `/www` on 8080.
    private func hostWithHTTPD() -> NetworkShell {
        let sh = NetworkShell()
        sh.run("mkdir /www")
        sh.run("mkdir /www/sub")
        sh.write("/www/index.html", "<h1>home</h1>\n")
        sh.write("/www/sub/a.txt", "alpha\n")
        sh.run("httpd -p 8080 /www &")
        return sh
    }

    /// A scripted HTTP server on 8081 whose behavior depends on the path.
    /// `/echo` reports the request it saw, one `key=value` per line.
    private func startScriptedServer(on sh: NetworkShell) {
        sh.kernel.spawn("scripted", args: ["scripted"]) { (ctx: ProcessContext) async in
            await Programs.serveTCP(ctx, port: 8081) { conn, fd in
                var buffer: [UInt8] = []
                while HTTP.endOfHeaders(buffer) == nil {
                    guard let chunk = try? await conn.tcpRecv(fd), !chunk.isEmpty else { return }
                    buffer.append(contentsOf: chunk)
                }
                guard let end = HTTP.endOfHeaders(buffer), let request = HTTP.parseRequest(buffer) else { return }
                let length = Int(request.headers["content-length"] ?? "") ?? 0
                while buffer.count < end + length {
                    guard let chunk = try? await conn.tcpRecv(fd), !chunk.isEmpty else { break }
                    buffer.append(contentsOf: chunk)
                }
                let body = String(decoding: buffer[end...], as: UTF8.self)
                func reply(_ status: String, headers: [String] = [], body: String) {
                    var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\n"
                    for header in headers { head += header + "\r\n" }
                    _ = conn.tcpSend(fd, Array((head + "\r\n" + body).utf8))
                }
                let path = String(request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
                switch path {
                case "/echo":
                    reply("200 OK", headers: ["Content-Type: text/plain"], body: """
                        method=\(request.method)
                        target=\(request.path)
                        host=\(request.headers["host"] ?? "-")
                        agent=\(request.headers["user-agent"] ?? "-")
                        accept=\(request.headers["accept"] ?? "-")
                        x-test=\(request.headers["x-test"] ?? "-")
                        type=\(request.headers["content-type"] ?? "-")
                        body=\(body)

                        """)
                case "/redirect":
                    reply("302 Found", headers: ["Location: /echo?via=redirect"], body: "go\n")
                case "/absolute":
                    reply("301 Moved Permanently", headers: ["Location: http://127.0.0.1:8081/echo?via=absolute"], body: "")
                case "/see-other":
                    reply("303 See Other", headers: ["Location: /echo"], body: "")
                case "/temporary":
                    reply("307 Temporary Redirect", headers: ["Location: /echo"], body: "")
                case "/loop":
                    reply("302 Found", headers: ["Location: /loop"], body: "")
                case "/secure":
                    reply("302 Found", headers: ["Location: https://example.test/"], body: "")
                case "/teapot":
                    reply("418 I'm a teapot", body: "short and stout\n")
                case "/chunked":
                    let wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                        + "5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n"
                    _ = conn.tcpSend(fd, Array(wire.utf8))
                case "/unframed":
                    _ = conn.tcpSend(fd, Array("HTTP/1.0 200 OK\r\n\r\nuntil close\n".utf8))
                case "/slow":
                    try? await conn.sleep(5)
                    reply("200 OK", body: "late\n")
                case "/hangup":
                    return
                default:
                    reply("404 Not Found", body: "nope\n")
                }
            }
        }
        sh.loop.runUntilIdle()
    }

    private func scriptedHost() -> NetworkShell {
        let sh = NetworkShell()
        startScriptedServer(on: sh)
        return sh
    }

    /// The body lines of an `/echo` reply as a dictionary.
    private func echoed(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            fields[String(line[line.startIndex..<equals])] = String(line[line.index(after: equals)...])
        }
        return fields
    }

    // MARK: - Pure helpers

    @Test func urlParsing() {
        typealias URL = BuiltinCommands.HTTPURL
        #expect(BuiltinCommands.parseURL("http://host/") == .success(URL(host: "host", port: 80, path: "/")))
        #expect(BuiltinCommands.parseURL("host:8080/a/b?q=1#frag") == .success(URL(host: "host", port: 8080, path: "/a/b?q=1")))
        #expect(BuiltinCommands.parseURL("HTTP://10.0.0.2") == .success(URL(host: "10.0.0.2", port: 80, path: "/")))
        #expect(BuiltinCommands.parseURL("http://host?x=1") == .success(URL(host: "host", port: 80, path: "/?x=1")))
        #expect(BuiltinCommands.parseURL("https://host/") == .failure(.unsupportedScheme("https")))
        #expect(BuiltinCommands.parseURL("ftp://host/") == .failure(.unsupportedScheme("ftp")))
        #expect(BuiltinCommands.parseURL("http://host:99999/") == .failure(.malformed))
        #expect(BuiltinCommands.parseURL("http:///path") == .failure(.malformed))
        let url = URL(host: "h", port: 8080, path: "/a/b?q=1")
        #expect(url.authority == "h:8080")
        #expect(url.text == "http://h:8080/a/b?q=1")
        #expect(url.pathOnly == "/a/b")
    }

    @Test func redirectResolution() {
        typealias URL = BuiltinCommands.HTTPURL
        let base = URL(host: "h", port: 8080, path: "/dir/page?x=1")
        #expect(BuiltinCommands.resolveRedirect("/other", from: base) == .success(URL(host: "h", port: 8080, path: "/other")))
        #expect(BuiltinCommands.resolveRedirect("next", from: base) == .success(URL(host: "h", port: 8080, path: "/dir/next")))
        #expect(BuiltinCommands.resolveRedirect("http://o:81/x", from: base) == .success(URL(host: "o", port: 81, path: "/x")))
        #expect(BuiltinCommands.resolveRedirect("//o/x", from: base) == .success(URL(host: "o", port: 80, path: "/x")))
        #expect(BuiltinCommands.resolveRedirect("https://o/", from: base) == .failure(.unsupportedScheme("https")))
    }

    @Test func writeOutExpansion() {
        let variables = ["http_code": "200", "size_download": "14"]
        #expect(BuiltinCommands.expandWriteOut("%{http_code}", variables: variables) == "200")
        #expect(BuiltinCommands.expandWriteOut("code=%{http_code} size=%{size_download}\\n", variables: variables)
                == "code=200 size=14\n")
        #expect(BuiltinCommands.expandWriteOut("%{unknown}|100%%|\\t|%", variables: variables) == "|100%|\t|%")
    }

    @Test func requestHeadersHonorOverridesAndRemovals() {
        var options = BuiltinCommands.CurlOptions()
        options.headers = ["X-Test: 1", "user-agent: mine", "Accept:"]
        let headers = BuiltinCommands.curlHeaders(options, hasBody: true)
        #expect(headers.map(\.name) == ["Content-Type", "X-Test", "user-agent"])
        #expect(headers.map(\.value) == ["application/x-www-form-urlencoded", "1", "mine"])
    }

    @Test func responseHeadAndChunkedDecoding() {
        let head = HTTP.parseResponseHead(Array("HTTP/1.1 404 Not Found\r\nContent-Length: 10\r\nX-A:  b \r\n\r\n".utf8))
        #expect(head?.status == 404)
        #expect(head?.statusLine == "HTTP/1.1 404 Not Found")
        #expect(head?.header("content-length") == "10")
        #expect(head?.header("x-a") == "b")
        #expect(HTTP.parseResponseHead(Array("garbage\r\n\r\n".utf8)) == nil)

        let whole = HTTP.decodeChunked(Array("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8))
        #expect(String(decoding: whole.body, as: UTF8.self) == "hello world")
        #expect(whole.complete)
        let partial = HTTP.decodeChunked(Array("5\r\nhello\r\n6\r\n wo".utf8))
        #expect(String(decoding: partial.body, as: UTF8.self) == "hello wo")
        #expect(!partial.complete)
        #expect(!HTTP.decodeChunked(Array("5\r\nhello\r\n".utf8)).complete)
    }

    /// CRLF is one grapheme in Swift, so header blocks must be split as bytes;
    /// otherwise `Connection: close` (and every other header) is never seen.
    @Test func requestHeadersAreParsedFromCRLFBlocks() {
        let request = HTTP.parseRequest(Array("GET /x HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n".utf8))
        #expect(request?.method == "GET")
        #expect(request?.path == "/x")
        #expect(request?.headers["host"] == "h")
        #expect(request?.keepAlive == false)
        #expect(HTTP.parseRequest(Array("GET / HTTP/1.1\r\nHost: h\r\n\r\n".utf8))?.keepAlive == true)
        #expect(HTTP.lines(Array("a\r\nb\nc\r\n\r\n".utf8)) == ["a", "b", "c"])
    }

    // MARK: - curl against httpd

    @Test func getPrintsTheBody() {
        let sh = hostWithHTTPD()
        let out = sh.run("curl http://127.0.0.1:8080/; echo rc=$?")
        #expect(out.contains("<h1>home</h1>\nrc=0"))
        #expect(!out.contains("HTTP/1.1"))
    }

    /// The reported failure: `curl -I url` said "cannot resolve -I".
    @Test(arguments: ["curl -I http://localhost:8080/", "curl --head http://localhost:8080/",
                      "curl http://localhost:8080/ -I"])
    func headRequestPrintsOnlyHeaders(line: String) {
        let sh = hostWithHTTPD()
        let out = sh.run(line)
        #expect(out.contains("HTTP/1.1 200 OK\n"), "\(out)")
        #expect(out.contains("Content-Length: 14\n"), "\(out)")
        #expect(out.contains("Content-Type: text/html\n"), "\(out)")
        #expect(!out.contains("<h1>home</h1>"), "\(out)")
        #expect(!out.contains("resolve"), "\(out)")
    }

    @Test func includeShowsHeadersThenBody() {
        let sh = hostWithHTTPD()
        let out = sh.run("curl -i http://localhost:8080/sub/a.txt")
        #expect(out.contains("HTTP/1.1 200 OK\nContent-Length: 6\nContent-Type: text/plain\nConnection: close\n\nalpha\n"))
    }

    @Test func outputToFileAndRemoteName() {
        let sh = hostWithHTTPD()
        let out = sh.run("curl -s -o /saved.txt http://localhost:8080/sub/a.txt; echo rc=$?")
        #expect(out.contains("rc=0"))
        #expect(!out.contains("alpha"))
        #expect(sh.read("/saved.txt") == "alpha\n")

        #expect(sh.run("curl --output /saved2.txt --silent http://localhost:8080/; echo rc=$?").contains("rc=0"))
        #expect(sh.read("/saved2.txt") == "<h1>home</h1>\n")

        sh.run("curl -sO http://localhost:8080/sub/a.txt")
        #expect(sh.read("/a.txt") == "alpha\n")

        let nameless = sh.run("curl -O http://localhost:8080/; echo rc=$?")
        #expect(nameless.contains("curl: (23) Remote file name has no length"))
        #expect(nameless.contains("rc=23"))
    }

    @Test func failTurnsHTTPErrorsIntoExit22() {
        let sh = hostWithHTTPD()
        let plain = sh.run("curl http://localhost:8080/missing; echo rc=$?")
        #expect(plain.contains("not found\nrc=0"))

        let failing = sh.run("curl -f http://localhost:8080/missing; echo rc=$?")
        #expect(failing.contains("curl: (22) The requested URL returned error: 404"))
        #expect(!failing.contains("not found"))
        #expect(failing.contains("rc=22"))

        let silent = sh.run("curl -fs http://localhost:8080/missing; echo rc=$?")
        #expect(!silent.contains("curl: (22)"))
        #expect(silent.contains("rc=22"))

        let shown = sh.run("curl -fsS http://localhost:8080/missing; echo rc=$?")
        #expect(shown.contains("curl: (22)"))
        #expect(shown.contains("rc=22"))

        #expect(sh.run("curl -f http://localhost:8080/; echo rc=$?").contains("rc=0"))
    }

    @Test func followsTheDirectoryRedirect() {
        let sh = hostWithHTTPD()
        let unfollowed = sh.run("curl -s -w '%{http_code}' http://localhost:8080/sub")
        #expect(unfollowed.contains("moved to /sub/\n301"))
        let followed = sh.run("curl -sL -w '%{http_code} %{num_redirects} %{url_effective}\\n' http://localhost:8080/sub")
        #expect(followed.contains("Index of /sub/"))
        #expect(followed.contains("200 1 http://localhost:8080/sub/\n"))
    }

    @Test func verbosePrintsBothHeadsOnStderr() {
        let sh = hostWithHTTPD()
        let out = sh.run("curl -v http://localhost:8080/sub/a.txt")
        #expect(out.contains("*   Trying 127.0.0.1:8080...\n"))
        #expect(out.contains("* Connected to localhost (127.0.0.1) port 8080\n"))
        #expect(out.contains("> GET /sub/a.txt HTTP/1.1\n> Host: localhost:8080\n> User-Agent: curl/swiftix\n> Accept: */*\n"))
        #expect(out.contains("< HTTP/1.1 200 OK\n< Content-Length: 6\n"))
        #expect(out.contains("alpha\n"))
        // The narration is stderr: redirecting it leaves only the body.
        let quiet = sh.run("curl -v http://localhost:8080/sub/a.txt 2>/dev/null")
        #expect(!quiet.contains("> GET"))
        #expect(quiet.contains("alpha\n"))
    }

    // MARK: - curl exit codes

    @Test func exitCodesForTransportFailures() {
        let sh = hostWithHTTPD()
        let https = sh.run("curl https://example.test/; echo rc=$?")
        #expect(https.contains("curl: (1) Protocol \"https\" not supported: this build has no TLS"))
        #expect(https.contains("rc=1"))
        #expect(!https.contains("usage"))

        let resolve = sh.run("curl http://nosuch.invalid/; echo rc=$?")
        #expect(resolve.contains("curl: (6) Could not resolve host: nosuch.invalid"))
        #expect(resolve.contains("rc=6"))

        let refused = sh.run("curl http://127.0.0.1:81/; echo rc=$?")
        #expect(refused.contains("curl: (7) Failed to connect to 127.0.0.1 port 81: Connection refused"))
        #expect(refused.contains("rc=7"))

        let silent = sh.run("curl -s http://127.0.0.1:81/; echo rc=$?")
        #expect(!silent.contains("curl: (7)"))
        #expect(silent.contains("rc=7"))

        let noURL = sh.run("curl -s; echo rc=$?")
        #expect(noURL.contains("curl: (2) no URL specified"))
        #expect(noURL.contains("rc=2"))

        let malformed = sh.run("curl http://host:notaport/; echo rc=$?")
        #expect(malformed.contains("curl: (3)"))
        #expect(malformed.contains("rc=3"))
    }

    @Test func maxTimeGivesExit28() {
        let sh = scriptedHost()
        var out = sh.run("curl -m 1 http://127.0.0.1:8081/slow; echo rc=$?")
        #expect(!out.contains("\nrc="))                      // still waiting at t=0
        out += sh.advance(1.5)
        #expect(out.contains("curl: (28) Operation timed out after 1000 milliseconds with 0 bytes received"))
        #expect(out.contains("rc=28"))
        #expect(!out.contains("late"))

        var patient = sh.run("curl --max-time 10 http://127.0.0.1:8081/slow; echo rc=$?")
        patient += sh.advance(6)
        #expect(patient.contains("late\nrc=0"))
    }

    @Test func connectTimeoutGivesExit28() {
        let sh = NetworkShell(ethernet: true)               // eth0 has no link: SYNs go nowhere
        var out = sh.run("curl --connect-timeout 2 http://10.0.0.9/; echo rc=$?")
        out += sh.advance(3)
        #expect(out.contains("curl: (28) Connection timed out after 2000 milliseconds"))
        #expect(out.contains("rc=28"))
    }

    @Test func emptyReplyGivesExit52() {
        let sh = scriptedHost()
        let out = sh.run("curl http://127.0.0.1:8081/hangup; echo rc=$?", advance: 1)
        #expect(out.contains("curl: (52) Empty reply from server"))
        #expect(out.contains("rc=52"))
    }

    // MARK: - curl request shaping

    @Test func defaultRequestLooksLikeCurl() {
        let sh = scriptedHost()
        let fields = echoed(sh.run("curl http://127.0.0.1:8081/echo?a=1"))
        #expect(fields["method"] == "GET")
        #expect(fields["target"] == "/echo?a=1")
        #expect(fields["host"] == "127.0.0.1:8081")
        #expect(fields["agent"] == "curl/swiftix")
        #expect(fields["accept"] == "*/*")
        #expect(fields["body"] == "")
    }

    @Test(arguments: ["curl -X PUT http://127.0.0.1:8081/echo", "curl --request PUT http://127.0.0.1:8081/echo",
                      "curl http://127.0.0.1:8081/echo -XPUT"])
    func requestMethodOverride(line: String) {
        let sh = scriptedHost()
        #expect(echoed(sh.run(line))["method"] == "PUT")
    }

    @Test func dataMakesAPostWithABody() {
        let sh = scriptedHost()
        var fields = echoed(sh.run("curl -d 'a=1' --data b=2 http://127.0.0.1:8081/echo"))
        #expect(fields["method"] == "POST")
        #expect(fields["type"] == "application/x-www-form-urlencoded")
        #expect(fields["body"] == "a=1&b=2")

        fields = echoed(sh.run("curl -X PATCH -d '{\"k\":1}' -H 'Content-Type: application/json' http://127.0.0.1:8081/echo"))
        #expect(fields["method"] == "PATCH")
        #expect(fields["type"] == "application/json")
        #expect(fields["body"] == "{\"k\":1}")

        sh.write("/payload", "from=file\n")
        fields = echoed(sh.run("curl -d @/payload http://127.0.0.1:8081/echo"))
        #expect(fields["body"] == "from=file")
        let missing = sh.run("curl -d @/nope http://127.0.0.1:8081/echo; echo rc=$?")
        #expect(missing.contains("rc=26"))
    }

    @Test func customHeadersAndUserAgent() {
        let sh = scriptedHost()
        var fields = echoed(sh.run("curl -H 'X-Test: yes' --header 'Accept: text/plain' http://127.0.0.1:8081/echo"))
        #expect(fields["x-test"] == "yes")
        #expect(fields["accept"] == "text/plain")
        fields = echoed(sh.run("curl -A probe/1 -H 'Accept:' http://127.0.0.1:8081/echo"))
        #expect(fields["agent"] == "probe/1")
        #expect(fields["accept"] == "-")
    }

    @Test func redirectsAreFollowedOnlyWithLocation() {
        let sh = scriptedHost()
        #expect(sh.run("curl http://127.0.0.1:8081/redirect").contains("go\n"))
        var fields = echoed(sh.run("curl -L http://127.0.0.1:8081/redirect"))
        #expect(fields["target"] == "/echo?via=redirect")
        fields = echoed(sh.run("curl --location http://127.0.0.1:8081/absolute"))
        #expect(fields["target"] == "/echo?via=absolute")

        let included = sh.run("curl -sLi http://127.0.0.1:8081/redirect")
        #expect(included.contains("HTTP/1.1 302 Found"))
        #expect(included.contains("HTTP/1.1 200 OK"))
    }

    @Test func redirectMethodRules() {
        let sh = scriptedHost()
        // 303 turns a POST into a GET and drops the body; 307 repeats it.
        var fields = echoed(sh.run("curl -L -d x=1 http://127.0.0.1:8081/see-other"))
        #expect(fields["method"] == "GET")
        #expect(fields["body"] == "")
        fields = echoed(sh.run("curl -L -d x=1 http://127.0.0.1:8081/temporary"))
        #expect(fields["method"] == "POST")
        #expect(fields["body"] == "x=1")
    }

    @Test func redirectsAreBounded() {
        let sh = scriptedHost()
        let limited = sh.run("curl -L --max-redirs 3 http://127.0.0.1:8081/loop; echo rc=$?")
        #expect(limited.contains("curl: (47) Maximum (3) redirects followed"))
        #expect(limited.contains("rc=47"))
        let byDefault = sh.run("curl -sSL http://127.0.0.1:8081/loop; echo rc=$?")
        #expect(byDefault.contains("curl: (47) Maximum (50) redirects followed"))

        let secure = sh.run("curl -L http://127.0.0.1:8081/secure; echo rc=$?")
        #expect(secure.contains("curl: (1) Protocol \"https\" not supported: this build has no TLS"))
        #expect(secure.contains("rc=1"))
    }

    @Test func writeOutReportsTheFinalResponse() {
        let sh = scriptedHost()
        #expect(sh.run("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/teapot; echo").contains("\n418\n"))
        let out = sh.run("curl -s -w 'code=%{response_code} type=%{content_type} size=%{size_download}\\n' http://127.0.0.1:8081/echo")
        #expect(out.contains("code=200 type=text/plain size="))
    }

    @Test func chunkedAndUnframedBodies() {
        let sh = scriptedHost()
        #expect(sh.run("curl -s http://127.0.0.1:8081/chunked; echo '|'").contains("\nhello world|\n"))
        #expect(sh.run("curl -s http://127.0.0.1:8081/unframed", advance: 1).contains("until close\n"))
    }

    @Test func severalURLsAreFetchedInOrder() {
        let sh = hostWithHTTPD()
        let out = sh.run("curl -s http://localhost:8080/sub/a.txt http://localhost:8080/; echo rc=$?")
        #expect(out.contains("alpha\n<h1>home</h1>\nrc=0"))
    }

    // MARK: - wget

    @Test func wgetSavesToTheNamedFile() {
        let sh = hostWithHTTPD()
        let out = sh.run("wget -O /w.txt http://localhost:8080/sub/a.txt; echo rc=$?")
        #expect(out.contains("wget: saved 6 bytes to /w.txt"))
        #expect(out.contains("rc=0"))
        #expect(sh.read("/w.txt") == "alpha\n")

        sh.run("wget http://localhost:8080/sub/a.txt")
        #expect(sh.read("/a.txt") == "alpha\n")
    }

    @Test func wgetQuietAndStdout() {
        let sh = hostWithHTTPD()
        let quiet = sh.run("wget -q -O /q.txt http://localhost:8080/; echo rc=$?")
        #expect(!quiet.contains("saved"))
        #expect(quiet.contains("rc=0"))
        #expect(sh.read("/q.txt") == "<h1>home</h1>\n")

        let piped = sh.run("wget -q -O - http://localhost:8080/sub/a.txt")
        #expect(piped.contains("\nalpha\n"))
        let notQuiet = sh.run("wget -O - http://localhost:8080/sub/a.txt")
        #expect(notQuiet.contains("alpha\n"))
        #expect(!notQuiet.contains("saved"))
        #expect(sh.read("/-") == nil)
    }

    @Test func wgetFollowsRedirectsAndReportsErrors() {
        let sh = hostWithHTTPD()
        sh.run("wget -q -O /listing.html http://localhost:8080/sub")
        #expect(sh.read("/listing.html")?.contains("Index of /sub/") == true)

        let https = sh.run("wget https://example.test/; echo rc=$?")
        #expect(https.contains("wget: Protocol \"https\" not supported: this build has no TLS"))
        #expect(https.contains("rc=1"))
        #expect(!https.contains("usage"))

        let missing = sh.run("wget http://localhost:8080/nope; echo rc=$?")
        #expect(missing.contains("wget: server returned error: HTTP/1.1 404 Not Found"))
        #expect(missing.contains("rc=8"))
        #expect(sh.read("/nope") == nil)

        let refused = sh.run("wget http://127.0.0.1:81/x; echo rc=$?")
        #expect(refused.contains("Connection refused"))
        #expect(refused.contains("rc=4"))

        let unresolved = sh.run("wget http://nosuch.invalid/x; echo rc=$?")
        #expect(unresolved.contains("wget: unable to resolve host address 'nosuch.invalid'"))
        #expect(unresolved.contains("rc=4"))
    }
}
