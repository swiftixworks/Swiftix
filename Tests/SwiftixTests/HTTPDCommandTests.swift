import Testing
@testable import Swiftix

/// The `httpd` command line and what it serves: files, index documents,
/// directory listings, HEAD, redirects and errors.
@Suite("httpd command")
struct HTTPDCommandTests {

    private func host(_ startLine: String = "httpd -p 8080 /www &") -> NetworkShell {
        let sh = NetworkShell()
        sh.run("mkdir /www")
        sh.run("mkdir /www/docs")
        sh.run("mkdir /www/empty")
        sh.write("/www/index.html", "<h1>home</h1>\n")
        sh.write("/www/docs/readme.txt", "read me\n")
        sh.write("/www/docs/data.json", "{}\n")
        sh.write("/www/docs/a b.txt", "spaced\n")
        sh.write("/secret", "outside the docroot\n")
        sh.run(startLine)
        return sh
    }

    @Test(arguments: ["httpd -p 8080 /www &", "httpd 8080 /www &", "httpd --port 8080 /www &", "httpd /www -p8080 &"])
    func portAndDocrootForms(line: String) {
        let sh = host(line)
        #expect(sh.run("curl -s http://127.0.0.1:8080/").contains("<h1>home</h1>"), "\(line)")
        #expect(sh.run("ss -tln").contains("0.0.0.0:8080"), "\(line)")
    }

    @Test func defaultsArePort80AndRootDirectory() {
        let sh = NetworkShell()
        sh.write("/index.html", "root index\n")
        #expect(sh.run("httpd &").contains("httpd: serving / on 80"))
        #expect(sh.run("curl -s http://127.0.0.1/").contains("root index"))
    }

    @Test func badArgumentsAreRejected() {
        let sh = NetworkShell()
        let notDirectory = sh.run("httpd /nowhere; echo rc=$?")
        #expect(notDirectory.contains("httpd: /nowhere: not a directory"))
        #expect(notDirectory.contains("rc=1"))
        let badPort = sh.run("httpd -p 0; echo rc=$?")
        #expect(badPort.contains("httpd: invalid port"))
        #expect(badPort.contains("rc=2"))
    }

    @Test func servesFilesWithLengthAndType() {
        let sh = host()
        let text = sh.run("curl -si http://127.0.0.1:8080/docs/readme.txt")
        #expect(text.contains("HTTP/1.1 200 OK\nContent-Length: 8\nContent-Type: text/plain\n"))
        #expect(text.contains("\n\nread me\n"))
        #expect(sh.run("curl -sI http://127.0.0.1:8080/docs/data.json").contains("Content-Type: application/json"))
        #expect(sh.run("curl -sI http://127.0.0.1:8080/index.html").contains("Content-Type: text/html"))
        #expect(sh.run("curl -s http://127.0.0.1:8080/docs/a%20b.txt").contains("spaced"))
        #expect(sh.run("curl -s 'http://127.0.0.1:8080/docs/readme.txt?v=2'").contains("read me"))
    }

    @Test func headHasHeadersAndNoBody() {
        let sh = host()
        let head = sh.run("curl -sI http://127.0.0.1:8080/docs/readme.txt; echo '|end'")
        #expect(head.contains("HTTP/1.1 200 OK\nContent-Length: 8\nContent-Type: text/plain\nConnection: close\n\n|end"))
        let missing = sh.run("curl -sI http://127.0.0.1:8080/nope")
        #expect(missing.contains("HTTP/1.1 404 Not Found\nContent-Length: 10\n"))
        #expect(!missing.contains("not found"))
    }

    @Test func directoriesServeIndexOrAListing() {
        let sh = host()
        #expect(sh.run("curl -s http://127.0.0.1:8080/").contains("<h1>home</h1>"))

        let listing = sh.run("curl -si http://127.0.0.1:8080/docs/")
        #expect(listing.contains("HTTP/1.1 200 OK"))
        #expect(listing.contains("Content-Type: text/html"))
        #expect(listing.contains("<h1>Index of /docs/</h1>"))
        #expect(listing.contains("<li><a href=\"../\">../</a></li>"))
        #expect(listing.contains("<li><a href=\"data.json\">data.json</a></li>\n<li><a href=\"readme.txt\">readme.txt</a></li>"))

        let empty = sh.run("curl -s http://127.0.0.1:8080/empty/")
        #expect(empty.contains("Index of /empty/"))
    }

    @Test func rootListingMarksSubdirectories() {
        let sh = NetworkShell()
        sh.run("mkdir /pub")
        sh.run("mkdir /pub/inner")
        sh.write("/pub/file.txt", "x")
        sh.run("httpd 8080 /pub &")
        let listing = sh.run("curl -s http://127.0.0.1:8080/")
        #expect(listing.contains("<h1>Index of /</h1>"))
        #expect(listing.contains("<li><a href=\"inner/\">inner/</a></li>"))
        #expect(listing.contains("<li><a href=\"file.txt\">file.txt</a></li>"))
        #expect(!listing.contains("../"))
    }

    @Test func directoryWithoutSlashRedirects() {
        let sh = host()
        let out = sh.run("curl -si http://127.0.0.1:8080/docs")
        #expect(out.contains("HTTP/1.1 301 Moved Permanently"))
        #expect(out.contains("Location: /docs/"))
    }

    @Test func errorsNotFoundForbiddenAndMethod() {
        let sh = host()
        let missing = sh.run("curl -si http://127.0.0.1:8080/nope")
        #expect(missing.contains("HTTP/1.1 404 Not Found\nContent-Length: 10\nContent-Type: text/plain\n"))
        #expect(missing.contains("not found\n"))

        // The docroot is a boundary: `..` never escapes it.
        for path in ["/../secret", "/docs/../../secret", "/%2e%2e/secret"] {
            let out = sh.run("curl -si 'http://127.0.0.1:8080\(path)'")
            #expect(out.contains("HTTP/1.1 403 Forbidden"), "\(path): \(out)")
            #expect(!out.contains("outside the docroot"), "\(path): \(out)")
        }

        let post = sh.run("curl -si -d x=1 http://127.0.0.1:8080/index.html")
        #expect(post.contains("HTTP/1.1 405 Method Not Allowed"))
        #expect(post.contains("Allow: GET, HEAD"))
    }

    @Test func targetMappingIsPure() {
        let sh = host("true")
        final class Box { var targets: [BuiltinCommands.HTTPDTarget] = [] }
        let box = Box()
        sh.kernel.spawn("map") { ctx in
            for target in ["/", "/docs", "/docs/", "/docs/readme.txt", "/nope", "/../secret", "relative", "/%zz"] {
                box.targets.append(BuiltinCommands.httpdTarget(ctx, docroot: "/www", requestTarget: target))
            }
            ctx.exit(0)
        }
        sh.loop.runUntilIdle()
        #expect(box.targets == [
            .file("/www/index.html"),
            .redirect("/docs/"),
            .listing(directory: "/www/docs", requestPath: "/docs/"),
            .file("/www/docs/readme.txt"),
            .notFound,
            .forbidden,
            .forbidden,
            .forbidden,
        ])
        #expect(BuiltinCommands.percentDecode("a%20b%2Fc") == "a b/c")
        #expect(BuiltinCommands.percentDecode("bad%2") == nil)
        #expect(BuiltinCommands.escapeHTML("<a&\"b\">") == "&lt;a&amp;&quot;b&quot;&gt;")
    }

    @Test func secondServerOnTheSamePortFails() {
        let sh = host()
        let out = sh.run("httpd -p 8080 /www; echo rc=$?")
        #expect(out.contains("address already in use"))
        #expect(out.contains("rc=1"))
        #expect(!out.contains("httpd: serving"))
    }
}
