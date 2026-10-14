/// `net/http`: a server whose handlers run, the client that reaches it, and
/// the library mechanism behind both.
///
/// Each program here starts a server on the loopback interface of its own
/// kernel, sends requests to itself (with `http.Get` and with raw requests
/// over `net.Dial`), and prints what it sees. The expected text is what the
/// same program printed under Go 1.24.5, with the `Date` header masked by the
/// program. The run is the synchronous one of `go run`, which drives the
/// event loop while goroutines wait, so nothing depends on wall-clock time.
///
/// Concurrency: every test builds its own `EventLoop` + `Kernel` and drives
/// it on the calling executor; nothing is shared between tests.

import Testing

@testable import Swiftix
@testable import SwiftixGo
@testable import SwiftixGoRuntime

@Suite("Go net/http")
struct GoHTTPServerTests: GoTestHarness {

    /// Runs `executable` as a process of a kernel that has a loopback
    /// interface, and returns what it printed on standard output.
    private func run(_ executable: GoExecutable) throws -> String {
        try runWithLog(executable).output
    }

    /// The same, with what the program wrote to standard error, which is
    /// where the server logs.
    private func runWithLog(_ executable: GoExecutable) throws -> (output: String, log: String) {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        let stack = kernel.netns.stack
        stack.configure(
            .addInterface(
                NetworkInterfaceConfiguration(
                    address: IPv4Address(127, 0, 0, 1),
                    mac: MACAddress("00:00:00:00:00:00")!,
                    prefixLength: 8)))
        let loopback = try #require(stack.interface(at: 0))
        loopback.onEgress = { [weak stack, weak loopback] frame in
            guard let stack, let loopback else { return }
            loop.schedule(after: 0) { stack.receive(frame, on: loopback) }
        }
        var output = ""
        var log = ""
        var failure: (any Error)?
        kernel.spawn("server") { context in
            // Descriptors 0, 1, and 2, so that no socket is given one of
            // them and standard error is a file to read back.
            for path in ["/stdin", "/stdout", "/stderr"] {
                _ = context.open(path, create: true, truncate: true)
            }
            do {
                _ = try GoVirtualMachine(maximumInstructions: 20_000_000).run(
                    executable, eventLoop: loop, processContext: context,
                    arguments: ["server"]
                ) { output += $0 }
                let descriptor = try context.openFile("/stderr", access: .readOnly)
                log = String(decoding: try context.readFile(descriptor, max: 65_536), as: UTF8.self)
            } catch {
                failure = error
            }
            context.exit(0)
        }
        loop.runUntilIdle()
        if let failure { throw failure }
        return (output, log)
    }

    private func run(_ source: String) throws -> String {
        try run(GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)]))
    }

    /// What the server of the first program logs: a handler that panics
    /// and a second `WriteHeader`, each after the time as Go's `log`
    /// writes it. Go adds the caller of `WriteHeader` and a stack trace,
    /// which a program of this toolchain cannot ask for.
    @Test func theServerLogsToStandardError() throws {
        let log = try runWithLog(
            GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: hc2Source)])
        ).log.split(separator: "\n").map(String.init)
        #expect(log.count == 2)
        #expect(log.first == "1970/01/01 00:00:00 http: superfluous response.WriteHeader call")
        #expect(log.last?.hasPrefix("1970/01/01 00:00:00 http: panic serving 127.0.0.1:") == true)
        #expect(log.last?.hasSuffix(": boom") == true)
    }

    /// Where what a program printed first differs from what it printed
    /// under Go, or nil when the two are the same.
    private func firstDifference(_ actual: String, from expected: String) -> String? {
        let printed = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let wanted = expected.split(separator: "\n", omittingEmptySubsequences: false)
        for index in 0..<max(printed.count, wanted.count) {
            let line = index < printed.count ? String(printed[index]) : "<nothing>"
            let goLine = index < wanted.count ? String(wanted[index]) : "<nothing>"
            if line != goLine { return "line \(index + 1): \(line) | Go printed: \(goLine)" }
        }
        return nil
    }

    /// The names of the functions of the image `source` compiles to.
    private func functionNames(_ source: String) throws -> [String] {
        try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
            .functions.map(\.name)
    }

    private func diagnostic(_ source: String) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return "\(diagnostic.position.line):\(diagnostic.position.column): \(diagnostic.message)"
        } catch {
            return "unexpected error: \(error)"
        }
    }

    // MARK: - Programs compared with Go

    /// Handlers that are a named function, a literal, a closure, a method value,
    /// and a variable; what a handler reads of a request and writes of a
    /// response; a slow handler beside another connection; a handler that
    /// panics.
    @Test func handlersOfEveryKindRunAndSeeTheRequest() throws {
        let difference = firstDifference(try run(hc2Source), from: hc2Expected)
        #expect(difference == nil, "\(difference ?? "")")
    }

    /// A middleware chain in the shape real servers have, with what the
    /// rest of the language now offers: a response writer that embeds
    /// `http.ResponseWriter` and overrides one method, an embedded mutex,
    /// method patterns with a wildcard, `defer resp.Body.Close()`,
    /// concurrent requests, and a sort with a callback.
    @Test func aMiddlewareChainWrapsTheResponseWriter() throws {
        #expect(try run(middlewareSource) == middlewareExpected)
    }

    /// `http.Handler`, `http.HandlerFunc`, `http.Handle`, `http.NewServeMux`, a
    /// server of any handler, and middleware of the shape
    /// `func(http.Handler) http.Handler`.
    @Test func handlerTypesAndMiddlewareCompose() throws {
        let difference = firstDifference(try run(hc3Source), from: hc3Expected)
        #expect(difference == nil, "\(difference ?? "")")
    }

    /// Raw HTTP/1.0 and HTTP/1.1 exchanges: the status line, `Content-Length`
    /// or chunks, the sniffed `Content-Type`, HEAD, keep-alive and
    /// `Connection: close`, redirects of the mux, and requests the server
    /// refuses.
    @Test func responsesAreTheBytesGoSends() throws {
        let difference = firstDifference(try run(hc4Source), from: hc4Expected)
        #expect(difference == nil, "\(difference ?? "")")
    }

    /// Exact paths, subtrees, the longest pattern, methods, wildcards and
    /// `PathValue`, hosts, and the panics of patterns that conflict.
    @Test func patternsRouteAsServeMuxRoutesThem() throws {
        let difference = firstDifference(try run(hc5Source), from: hc5Expected)
        #expect(difference == nil, "\(difference ?? "")")
    }

    /// A second package of the module, imports under other names, a type
    /// alias, and a type a function declares, around the library's types;
    /// `http.Post`, `http.PostForm`, the errors of the client, and `net/url`.
    @Test func aSecondPackageAndRenamedImportsUseTheLibrary() throws {
        let executable = try GoCompiler.compile(
            packages: [
                GoPackageSource(
                    importPath: "example/hc6",
                    sources: [GoSourceFile(path: "main.go", text: hc6Source)]),
                GoPackageSource(
                    importPath: "example/hc6/api",
                    sources: [GoSourceFile(path: "api/api.go", text: hc6APISource)]),
            ],
            root: "example/hc6")
        let difference = firstDifference(try run(executable), from: hc6Expected)
        #expect(difference == nil, "\(difference ?? "")")
    }

    /// `http.ListenAndServe` in a goroutine with the default mux, an
    /// `http.Server` with an address and a handler, `http.Flusher`, and
    /// `http.Head`.
    @Test func listenAndServeStartsAServer() throws {
        let difference = firstDifference(try run(hc7Source), from: hc7Expected)
        #expect(difference == nil, "\(difference ?? "")")
    }

    // MARK: - The library mechanism

    /// A program that uses none of the Go-written library is compiled as it
    /// was before there was one: nothing is linked with it. One that uses a
    /// member of `io` that is written in Go gets that package and no other.
    @Test func aProgramIsLinkedOnlyWithWhatItUses() throws {
        let plain = try functionNames(
            """
            package main
            import "fmt"
            import "io"
            import "strings"
            func main() {
                var err error = io.EOF
                fmt.Println(err == io.EOF, io.SeekEnd, strings.ToUpper("x"))
            }
            """)
        #expect(plain == ["main"])

        let reader = try functionNames(
            """
            package main
            import "fmt"
            import "io"
            import "strings"
            func main() {
                data, err := io.ReadAll(strings.NewReader("text"))
                fmt.Println(string(data), err, err == io.EOF)
            }
            """)
        #expect(reader.contains("io.ReadAll"))
        #expect(reader.contains("strings.NewReader"))
        #expect(!reader.contains { $0.hasPrefix("net/http.") })

        let server = try functionNames(
            """
            package main
            import "net/http"
            func main() {
                http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {})
            }
            """)
        #expect(server.contains("net/http.HandleFunc"))
        #expect(server.contains("net/url.Parse"))
    }

    /// The members of `io` and `strings` that are written in Go, in a
    /// program that has nothing to do with HTTP, under the names a file
    /// gives the packages. Expected output is Go's.
    @Test func ioAndStringsMembersWrittenInGo() throws {
        let output = try runGoMain(
            """
            var r stdio.Reader = text.NewReader("hello, reader")
            head := make([]byte, 5)
            n, err := r.Read(head)
            f.Println(n, err, string(head))
            rest, err := stdio.ReadAll(r)
            f.Println(string(rest), err, err == stdio.EOF)
            var sink collector
            m, err := stdio.WriteString(&sink, "written ")
            f.Fprintf(&sink, "%d bytes", m)
            f.Fprintln(&sink, "", err)
            copied, err := stdio.Copy(&sink, text.NewReader("copied"))
            f.Println(sink.text, copied, err)
            rc := stdio.NopCloser(text.NewReader("x"))
            f.Println(rc.Close(), stdio.ErrUnexpectedEOF)
            """,
            imports: [],
            declarations: """
                import (
                    f "fmt"
                    stdio "io"
                    text "strings"
                )
                type collector struct {
                    text string
                }
                func (c *collector) Write(p []byte) (int, error) {
                    c.text += string(p)
                    return len(p), nil
                }
                """)
        #expect(
            output == """
                5 <nil> hello
                , reader <nil> false
                written 8 bytes <nil>
                copied 6 <nil>
                <nil> unexpected EOF

                """)
    }

    /// An image that holds the instructions the first `net/http` compiled
    /// to keeps running: the VM executes them as it did.
    @Test func imagesWithTheOldInstructionsStillRun() throws {
        let executable = GoExecutable(
            entryPoint: "main",
            functions: [
                GoBytecodeFunction(
                    name: "main", localCount: 0,
                    instructions: [
                        .push(.string("/")), .httpHandleFunc("main"),
                        .push(.string(":80")), .httpListenAndServe,
                        .print(argumentCount: 1, newline: true),
                        .push(.string("http://10.0.0.1/")), .httpGet,
                        .print(argumentCount: 2, newline: true),
                        .return,
                    ])
            ])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(
            output == """
                net/http: network not available
                <nil> net/http: network not available

                """)
    }

    /// Every file of the library parses, and each native package that has
    /// members written in Go knows which they are: a file that did not
    /// parse would leave its names to the native package without a word.
    @Test func theLibraryParses() throws {
        for path in GoSourceLibraryText.paths {
            for source in GoSourceLibraryText.files(ofPackage: path) ?? [] {
                _ = try GoParser.parse(source)
            }
            #expect(GoSourceLibraryText.declared[path]?.isEmpty == false)
        }
        #expect(GoSourceLibrary.declares(path: "io", member: "ReadAll"))
        #expect(!GoSourceLibrary.declares(path: "io", member: "EOF"))
        #expect(GoSourceLibraryText.declared["strings"]?.isSuperset(of: ["NewReader", "Reader"]) == true)
    }

    // MARK: - Diagnostics

    @Test func mistakesAreReportedInGoSpelling() {
        func body(_ text: String) -> String {
            "package main\nimport \"fmt\"\nimport \"net/http\"\nfunc main() {\n\t\(text)\n\tfmt.Println()\n}\n"
        }
        #expect(diagnostic(body("http.Nope()")) == "5:7: undefined: http.Nope")
        #expect(
            diagnostic(body("http.HandleFunc(\"/\", 42)"))
                == "5:23: cannot use 42 (untyped int constant) as func(http.ResponseWriter, *http.Request) value in argument to http.HandleFunc")
        #expect(
            diagnostic(body("var h http.Handler = 1\n\t_ = h"))
                == "5:23: cannot use 1 (constant of type int) as http.Handler value in variable declaration: int does not implement http.Handler (missing method ServeHTTP)")
        #expect(
            diagnostic("package main\nimport \"net/http\"\nfunc main() {}\n")
                == "2:8: \"net/http\" imported and not used")
        #expect(
            diagnostic(
                "package main\nimport \"fmt\"\nfunc main() {\n\tfmt.Fprintln(42, \"x\")\n}\n")
                == "4:15: cannot use 42 (constant of type int) as io.Writer value in argument to fmt.Fprintln: int does not implement io.Writer (missing method Write)")
    }

    // MARK: - Natives

    /// The work the VM does for the library, against what Go returns.
    @Test func nativesFollowGo() {
        #expect(GoHTTP.canonicalHeaderKey("content-type") == "Content-Type")
        #expect(GoHTTP.canonicalHeaderKey("x-FORWARDED-for") == "X-Forwarded-For")
        #expect(GoHTTP.canonicalHeaderKey("not a token") == "not a token")
        #expect(GoHTTP.isToken("GET") && !GoHTTP.isToken("") && !GoHTTP.isToken("G ET"))
        #expect(GoHTTP.isHeaderValue("a\tb é") && !GoHTTP.isHeaderValue("a\nb"))
        #expect(GoHTTP.lineEnd(Array("ab\ncd\n".utf8), from: 0) == 3)
        #expect(GoHTTP.lineEnd(Array("ab\ncd\n".utf8), from: 3) == 6)
        #expect(GoHTTP.lineEnd(Array("ab".utf8), from: 0) == -1)
        #expect(
            GoHTTP.formatTime(unixSeconds: 0, layout: .header) == "Thu, 01 Jan 1970 00:00:00 GMT")
        #expect(
            GoHTTP.formatTime(unixSeconds: 1_709_210_096, layout: .header)
                == "Thu, 29 Feb 2024 12:34:56 GMT")
        #expect(
            GoHTTP.formatTime(unixSeconds: 1_709_210_096, layout: .log) == "2024/02/29 12:34:56")

        func sniff(_ text: String) -> String { GoHTTP.detectContentType(Array(text.utf8)) }
        #expect(sniff("plain words") == "text/plain; charset=utf-8")
        #expect(sniff("  \n<!doctype html><p>") == "text/html; charset=utf-8")
        #expect(sniff("<b>bold</b>") == "text/html; charset=utf-8")
        #expect(sniff("<bold>") == "text/plain; charset=utf-8")
        #expect(sniff("<?xml version=\"1.0\"?>") == "text/xml; charset=utf-8")
        #expect(sniff("%PDF-1.7") == "application/pdf")
        #expect(sniff("GIF89a...") == "image/gif")
        #expect(sniff("") == "text/plain; charset=utf-8")
        #expect(GoHTTP.detectContentType([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) == "image/png")
        #expect(GoHTTP.detectContentType([0x00, 0x01, 0x02]) == "application/octet-stream")
        #expect(GoHTTP.detectContentType([0x1F, 0x8B, 0x08, 0x00]) == "application/x-gzip")

        #expect(GoURL.escape("a b&c=d/é", .queryComponent) == "a+b%26c%3Dd%2F%C3%A9")
        #expect(GoURL.escape("a b/c", .pathSegment) == "a%20b%2Fc")
        #expect(GoURL.escape("/a b/c?", .path) == "/a%20b/c%3F")
        #expect(GoURL.unescape("a+b%26c", .queryComponent) == .success(Array("a b&c".utf8)))
        #expect(GoURL.unescape("a+b%2", .path) == .failure(.escape("%2")))
        #expect(GoURL.unescape("ex ample.com", .host) == .failure(.host(" ")))
        #expect(GoURL.isValidEncoded("/a%20b", .path) && !GoURL.isValidEncoded("/a b", .path))
        #expect(GoURL.hasControlByte("a\u{7F}") && !GoURL.hasControlByte("abc"))
    }
}

private let hc2Source = #"""
package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
)

var addr string

type counter struct {
	mu sync.Mutex
	n  int
}

func (c *counter) hit(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	c.n++
	n := c.n
	c.mu.Unlock()
	fmt.Fprintf(w, "count %d\n", n)
}

func named(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "named", r.Method, r.URL.Path)
}

func inspect(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	cerr := r.Body.Close()
	remote := r.RemoteAddr[:strings.LastIndex(r.RemoteAddr, ":")]
	fmt.Fprintf(w, "method=%s path=%s raw=%s q=%s missing=%q\n", r.Method, r.URL.Path, r.URL.RawQuery, r.URL.Query().Get("q"), r.URL.Query().Get("zz"))
	fmt.Fprintf(w, "host=%v remote=%s proto=%s %d.%d len=%d uri=%s\n", r.Host == addr, remote, r.Proto, r.ProtoMajor, r.ProtoMinor, r.ContentLength, r.RequestURI)
	fmt.Fprintf(w, "ua=%s x=%s ct=%q\n", r.Header.Get("User-Agent"), r.Header.Get("x-custom"), r.Header.Get("Content-Type"))
	fmt.Fprintf(w, "body=%q %v %v\n", body, err, cerr)
	fmt.Fprintf(w, "%T %T %T %T\n", w, r, r.URL, r.Header)
}

func writes(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("X-One", "1")
	h.Add("X-Many", "a")
	h.Add("x-many", "b")
	h.Set("X-Gone", "x")
	h.Del("x-gone")
	h.Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusAccepted)
	n, err := w.Write([]byte("bytes\n"))
	fmt.Fprint(w, "print ", n, err, "\n")
	m, err := io.WriteString(w, "string\n")
	fmt.Fprintln(w, "println", m, err, h.Get("X-Many"), len(h["X-Many"]))
}

func get(path string) {
	resp, err := http.Get("http://" + addr + path)
	if err != nil {
		fmt.Println("GET", path, "error:", strings.Join(strings.Split(err.Error(), addr), "ADDR"))
		return
	}
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Printf("GET %s -> %s len=%d ct=%q err=%v\n%s", path, resp.Status, resp.ContentLength, resp.Header.Get("Content-Type"), err, body)
	for _, k := range []string{"X-One", "X-Many", "X-Gone", "Location", "Allow", "X-Content-Type-Options"} {
		if v := resp.Header[k]; len(v) > 0 {
			fmt.Println("  ", k, v)
		}
	}
}

func main() {
	port := "18082"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	addr = "127.0.0.1:" + port

	c := &counter{}
	prefix := "closure"
	calls := 0
	var variable func(http.ResponseWriter, *http.Request)
	variable = func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "variable")
	}
	release := make(chan bool)
	started := make(chan bool)

	http.HandleFunc("/named", named)
	http.HandleFunc("/literal", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "literal")
	})
	http.HandleFunc("/closure", func(w http.ResponseWriter, r *http.Request) {
		calls++
		fmt.Fprintln(w, prefix, calls)
	})
	http.HandleFunc("/method", c.hit)
	http.HandleFunc("/variable", variable)
	http.HandleFunc("/inspect", inspect)
	http.HandleFunc("/writes", writes)
	http.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		started <- true
		<-release
		fmt.Fprintln(w, "slow done")
	})
	http.HandleFunc("/panic", func(w http.ResponseWriter, r *http.Request) {
		panic("boom")
	})
	http.HandleFunc("/error", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "no such luck", http.StatusTeapot)
	})
	http.HandleFunc("/notfound", func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})
	http.HandleFunc("/redirect", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/named", http.StatusFound)
	})
	http.HandleFunc("/late", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "first")
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintln(w, "second")
	})

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Println("listen:", err)
		return
	}
	go http.Serve(ln, nil)

	for _, p := range []string{"/named", "/literal", "/closure", "/closure", "/method", "/method", "/variable", "/writes", "/error", "/notfound", "/redirect", "/late", "/nothing/here"} {
		get(p)
	}
	get("/inspect?q=go+lang&x=%41")

	req, _ := http.NewRequest("POST", "http://"+addr+"/inspect", strings.NewReader("posted body"))
	req.Header.Set("X-Custom", "yes")
	req.Header.Set("Content-Type", "text/plain")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Println("post:", err)
		return
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Printf("POST -> %d\n%s", resp.StatusCode, body)

	// A slow handler does not hold up another connection.
	done := make(chan bool)
	go func() {
		get("/slow")
		done <- true
	}()
	<-started
	get("/named")
	release <- true
	<-done

	// A handler that panics ends its own request.
	get("/panic")
	get("/named")
	fmt.Println(calls, c.n, http.StatusText(http.StatusNotFound), http.StatusOK, http.MethodGet, http.MethodPost)
}
"""#

private let hc2Expected = #"""
GET /named -> 200 OK len=17 ct="text/plain; charset=utf-8" err=<nil>
named GET /named
GET /literal -> 200 OK len=8 ct="text/plain; charset=utf-8" err=<nil>
literal
GET /closure -> 200 OK len=10 ct="text/plain; charset=utf-8" err=<nil>
closure 1
GET /closure -> 200 OK len=10 ct="text/plain; charset=utf-8" err=<nil>
closure 2
GET /method -> 200 OK len=8 ct="text/plain; charset=utf-8" err=<nil>
count 1
GET /method -> 200 OK len=8 ct="text/plain; charset=utf-8" err=<nil>
count 2
GET /variable -> 200 OK len=9 ct="text/plain; charset=utf-8" err=<nil>
variable
GET /writes -> 202 Accepted len=47 ct="text/plain; charset=utf-8" err=<nil>
bytes
print 6 <nil>
string
println 7 <nil> a 2
   X-One [1]
   X-Many [a b]
GET /error -> 418 I'm a teapot len=13 ct="text/plain; charset=utf-8" err=<nil>
no such luck
   X-Content-Type-Options [nosniff]
GET /notfound -> 404 Not Found len=19 ct="text/plain; charset=utf-8" err=<nil>
404 page not found
   X-Content-Type-Options [nosniff]
GET /redirect -> 200 OK len=17 ct="text/plain; charset=utf-8" err=<nil>
named GET /named
GET /late -> 200 OK len=13 ct="text/plain; charset=utf-8" err=<nil>
first
second
GET /nothing/here -> 404 Not Found len=19 ct="text/plain; charset=utf-8" err=<nil>
404 page not found
   X-Content-Type-Options [nosniff]
GET /inspect?q=go+lang&x=%41 -> 200 OK len=248 ct="text/plain; charset=utf-8" err=<nil>
method=GET path=/inspect raw=q=go+lang&x=%41 q=go lang missing=""
host=true remote=127.0.0.1 proto=HTTP/1.1 1.1 len=0 uri=/inspect?q=go+lang&x=%41
ua=Go-http-client/1.1 x= ct=""
body="" <nil> <nil>
*http.response *http.Request *url.URL http.Header
POST -> 200
method=POST path=/inspect raw= q= missing=""
host=true remote=127.0.0.1 proto=HTTP/1.1 1.1 len=11 uri=/inspect
ua=Go-http-client/1.1 x=yes ct="text/plain"
body="posted body" <nil> <nil>
*http.response *http.Request *url.URL http.Header
GET /named -> 200 OK len=17 ct="text/plain; charset=utf-8" err=<nil>
named GET /named
GET /slow -> 200 OK len=10 ct="text/plain; charset=utf-8" err=<nil>
slow done
GET /panic error: Get "http://ADDR/panic": EOF
GET /named -> 200 OK len=17 ct="text/plain; charset=utf-8" err=<nil>
named GET /named
2 2 Not Found 200 GET POST

"""#

private let hc3Source = #"""
package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
)

var addr string

// A handler that is a type of the program.
type greeter struct {
	greeting string
}

func (g greeter) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "%s, %s\n", g.greeting, strings.TrimPrefix(r.URL.Path, "/greet/"))
}

type hits struct {
	mu    sync.Mutex
	paths []string
}

func (h *hits) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	h.paths = append(h.paths, r.URL.Path)
	n := len(h.paths)
	h.mu.Unlock()
	fmt.Fprintln(w, "hit", n)
}

// Middleware: a function from a handler to a handler.
func logging(log *[]string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*log = append(*log, "before "+r.Method+" "+r.URL.Path)
		next.ServeHTTP(w, r)
		*log = append(*log, "after "+r.URL.Path)
	})
}

func header(key, value string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set(key, value)
			next.ServeHTTP(w, r)
		})
	}
}

func requireMethod(method string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != method {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func chain(h http.Handler, middleware ...func(http.Handler) http.Handler) http.Handler {
	for i := len(middleware) - 1; i >= 0; i-- {
		h = middleware[i](h)
	}
	return h
}

func show(method, path string) {
	req, err := http.NewRequest(method, "http://"+addr+path, nil)
	if err != nil {
		fmt.Println("request:", err)
		return
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Println(method, path, "error:", err)
		return
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Printf("%s %s -> %d %q x=%q\n", method, path, resp.StatusCode, body, resp.Header.Get("X-Served-By"))
}

func main() {
	port := "18083"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	addr = "127.0.0.1:" + port

	var log []string
	counted := &hits{}

	mux := http.NewServeMux()
	mux.Handle("/greet/", greeter{greeting: "hello"})
	mux.Handle("/hits", counted)
	mux.HandleFunc("/func", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "func\n")
	})
	mux.Handle("/post", requireMethod("POST", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "posted")
	})))
	mux.Handle("/gone", http.NotFoundHandler())
	mux.Handle("/moved", http.RedirectHandler("/func", http.StatusMovedPermanently))
	mux.Handle("/static/", http.StripPrefix("/static", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "static", r.URL.Path)
	})))

	var root http.Handler = chain(mux, header("X-Served-By", "mux"), func(next http.Handler) http.Handler {
		return logging(&log, next)
	})
	fmt.Printf("%T %T %T\n", mux, http.HandlerFunc(nil), counted)

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Println("listen:", err)
		return
	}
	go http.Serve(ln, root)

	show("GET", "/greet/world")
	show("GET", "/hits")
	show("GET", "/hits")
	show("GET", "/func")
	show("GET", "/post")
	show("POST", "/post")
	show("GET", "/gone")
	show("GET", "/moved")
	show("GET", "/static/a/b")
	show("GET", "/missing")
	for _, line := range log {
		fmt.Println(line)
	}
	fmt.Println(counted.paths)

	// The default mux and http.Handle, on a second server.
	http.Handle("/default", greeter{greeting: "default"})
	http.HandleFunc("/also", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "also")
	})
	ln2, err := net.Listen("tcp", "127.0.0.1:"+fmt.Sprint(len(port)+10000+len(log)))
	if err != nil {
		fmt.Println("listen:", err)
		return
	}
	addr = "127.0.0.1:" + fmt.Sprint(len(port)+10000+len(log))
	go http.Serve(ln2, nil)
	show("GET", "/default")
	show("GET", "/also")
	show("GET", "/")
}
"""#

private let hc3Expected = #"""
*http.ServeMux http.HandlerFunc *main.hits
GET /greet/world -> 200 "hello, world\n" x="mux"
GET /hits -> 200 "hit 1\n" x="mux"
GET /hits -> 200 "hit 2\n" x="mux"
GET /func -> 200 "func\n" x="mux"
GET /post -> 405 "method not allowed\n" x="mux"
POST /post -> 200 "posted\n" x="mux"
GET /gone -> 404 "404 page not found\n" x="mux"
GET /moved -> 200 "func\n" x="mux"
GET /static/a/b -> 200 "static /a/b\n" x="mux"
GET /missing -> 404 "404 page not found\n" x="mux"
before GET /greet/world
after /greet/world
before GET /hits
after /hits
before GET /hits
after /hits
before GET /func
after /func
before GET /post
after /post
before POST /post
after /post
before GET /gone
after /gone
before GET /moved
after /moved
before GET /func
after /func
before GET /static/a/b
after /static/a/b
before GET /missing
after /missing
[/hits /hits]
GET /default -> 200 "default, /default\n" x=""
GET /also -> 200 "also\n" x=""
GET / -> 404 "404 page not found\n" x=""

"""#

private let hc4Source = #"""
package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
)

var addr string

// raw sends the request as it is and prints the response as it came, a
// line at a time, with the date masked.
func raw(title, request string) {
	fmt.Println("==", title)
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		fmt.Println("dial:", err)
		return
	}
	conn.Write([]byte(request))
	var all []byte
	buf := make([]byte, 4096)
	for {
		n, err := conn.Read(buf)
		all = append(all, buf[:n]...)
		if err != nil {
			break
		}
	}
	conn.Close()
	text := string(all)
	if len(text) > 700 {
		text = text[:300] + "<...>" + text[len(text)-80:]
	}
	for _, line := range strings.Split(text, "\r\n") {
		if strings.HasPrefix(line, "Date: ") {
			line = "Date: <date>"
		}
		fmt.Printf("%q\n", line)
	}
}

func main() {
	port := "18084"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	addr = "127.0.0.1:" + port

	http.HandleFunc("/text", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "plain text")
	})
	http.HandleFunc("/html", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "<html><body>hi</body></html>")
	})
	http.HandleFunc("/json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, "{\"ok\":true}")
	})
	http.HandleFunc("/empty", func(w http.ResponseWriter, r *http.Request) {})
	http.HandleFunc("/created", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
	})
	http.HandleFunc("/nocontent", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	http.HandleFunc("/late", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "body first")
		w.WriteHeader(http.StatusTeapot)
	})
	http.HandleFunc("/big", func(w http.ResponseWriter, r *http.Request) {
		for i := 0; i < 5; i++ {
			fmt.Fprint(w, strings.Repeat("x", 999), "\n")
		}
	})
	http.HandleFunc("/length", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "5")
		fmt.Fprint(w, "12345")
	})
	http.HandleFunc("/close", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Connection", "close")
		fmt.Fprintln(w, "bye")
	})
	http.HandleFunc("/odd", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(599)
		fmt.Fprintln(w, "odd")
	})
	http.HandleFunc("/dir/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "dir", r.URL.Path)
	})
	http.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		buf := make([]byte, 64)
		n, _ := r.Body.Read(buf)
		fmt.Fprintf(w, "%s %d %q\n", r.Method, r.ContentLength, buf[:n])
	})

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Println("listen:", err)
		return
	}
	go http.Serve(ln, nil)

	raw("1.0 text", "GET /text HTTP/1.0\r\n\r\n")
	raw("1.1 text close", "GET /text HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 html", "GET /html HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 json", "GET /json HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 empty", "GET /empty HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 created", "GET /created HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 no content", "GET /nocontent HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 late header", "GET /late HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 big", "GET /big HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.0 big", "GET /big HTTP/1.0\r\n\r\n")
	raw("1.1 declared length", "GET /length HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 handler closes", "GET /close HTTP/1.1\r\nHost: h\r\n\r\n")
	raw("1.1 odd status", "GET /odd HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 head", "HEAD /text HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 not found", "GET /nope HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.0 not found", "GET /nope HTTP/1.0\r\n\r\n")
	raw("1.1 dir redirect", "GET /dir HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 dir", "GET /dir/a/b HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 unclean path", "GET /dir/../text HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.1 keep-alive, two requests", "GET /text HTTP/1.1\r\nHost: h\r\n\r\nGET /empty HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	raw("1.0 keep-alive", "GET /text HTTP/1.0\r\nConnection: keep-alive\r\n\r\nGET /text HTTP/1.0\r\n\r\n")
	raw("1.1 post", "POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
	raw("1.1 chunked post", "POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
	raw("malformed", "NONSENSE\r\n\r\n")
	raw("no host", "GET /text HTTP/1.1\r\n\r\n")
	raw("bad version", "GET /text HTTP/9.9\r\nHost: h\r\n\r\n")
	raw("bad header", "GET /text HTTP/1.1\r\nHost: h\r\nNo colon here\r\n\r\n")
	raw("lf only", "GET /text HTTP/1.0\n\n")
}
"""#

private let hc4Expected = #"""
== 1.0 text
"HTTP/1.0 200 OK"
"Date: <date>"
"Content-Length: 11"
"Content-Type: text/plain; charset=utf-8"
""
"plain text\n"
== 1.1 text close
"HTTP/1.1 200 OK"
"Date: <date>"
"Content-Length: 11"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
"plain text\n"
== 1.1 html
"HTTP/1.1 200 OK"
"Date: <date>"
"Content-Length: 28"
"Content-Type: text/html; charset=utf-8"
"Connection: close"
""
"<html><body>hi</body></html>"
== 1.1 json
"HTTP/1.1 200 OK"
"Content-Type: application/json"
"Date: <date>"
"Content-Length: 11"
"Connection: close"
""
"{\"ok\":true}"
== 1.1 empty
"HTTP/1.1 200 OK"
"Date: <date>"
"Content-Length: 0"
"Connection: close"
""
""
== 1.1 created
"HTTP/1.1 201 Created"
"Date: <date>"
"Content-Length: 0"
"Connection: close"
""
""
== 1.1 no content
"HTTP/1.1 204 No Content"
"Date: <date>"
"Connection: close"
""
""
== 1.1 late header
"HTTP/1.1 200 OK"
"Date: <date>"
"Content-Length: 11"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
"body first\n"
== 1.1 big
"HTTP/1.1 200 OK"
"Date: <date>"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
"Transfer-Encoding: chunked"
""
"800"
"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx<...>xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n"
"0"
""
""
== 1.0 big
"HTTP/1.0 200 OK"
"Date: <date>"
"Content-Type: text/plain; charset=utf-8"
""
"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx<...>xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n"
== 1.1 declared length
"HTTP/1.1 200 OK"
"Content-Length: 5"
"Date: <date>"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
"12345"
== 1.1 handler closes
"HTTP/1.1 200 OK"
"Connection: close"
"Date: <date>"
"Content-Length: 4"
"Content-Type: text/plain; charset=utf-8"
""
"bye\n"
== 1.1 odd status
"HTTP/1.1 599 status code 599"
"Date: <date>"
"Content-Length: 4"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
"odd\n"
== 1.1 head
"HTTP/1.1 200 OK"
"Date: <date>"
"Content-Length: 11"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
""
== 1.1 not found
"HTTP/1.1 404 Not Found"
"Content-Type: text/plain; charset=utf-8"
"X-Content-Type-Options: nosniff"
"Date: <date>"
"Content-Length: 19"
"Connection: close"
""
"404 page not found\n"
== 1.0 not found
"HTTP/1.0 404 Not Found"
"Content-Type: text/plain; charset=utf-8"
"X-Content-Type-Options: nosniff"
"Date: <date>"
"Content-Length: 19"
""
"404 page not found\n"
== 1.1 dir redirect
"HTTP/1.1 301 Moved Permanently"
"Content-Type: text/html; charset=utf-8"
"Location: /dir/"
"Date: <date>"
"Content-Length: 40"
"Connection: close"
""
"<a href=\"/dir/\">Moved Permanently</a>.\n\n"
== 1.1 dir
"HTTP/1.1 200 OK"
"Date: <date>"
"Content-Length: 13"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
"dir /dir/a/b\n"
== 1.1 unclean path
"HTTP/1.1 301 Moved Permanently"
"Content-Type: text/html; charset=utf-8"
"Location: /text"
"Date: <date>"
"Content-Length: 40"
"Connection: close"
""
"<a href=\"/text\">Moved Permanently</a>.\n\n"
== 1.1 keep-alive, two requests
"HTTP/1.1 200 OK"
"Date: <date>"
"Content-Length: 11"
"Content-Type: text/plain; charset=utf-8"
""
"plain text\nHTTP/1.1 200 OK"
"Date: <date>"
"Content-Length: 0"
"Connection: close"
""
""
== 1.0 keep-alive
"HTTP/1.0 200 OK"
"Date: <date>"
"Content-Length: 11"
"Content-Type: text/plain; charset=utf-8"
"Connection: keep-alive"
""
"plain text\nHTTP/1.0 200 OK"
"Date: <date>"
"Content-Length: 11"
"Content-Type: text/plain; charset=utf-8"
""
"plain text\n"
== 1.1 post
"HTTP/1.1 200 OK"
"Date: <date>"
"Content-Length: 15"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
"POST 5 \"hello\"\n"
== 1.1 chunked post
"HTTP/1.1 200 OK"
"Date: <date>"
"Content-Length: 16"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
"POST -1 \"hello\"\n"
== malformed
"HTTP/1.1 400 Bad Request"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
"400 Bad Request"
== no host
"HTTP/1.1 400 Bad Request: missing required Host header"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
"400 Bad Request: missing required Host header"
== bad version
"HTTP/1.1 505 HTTP Version Not Supported: unsupported protocol version"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
"505 HTTP Version Not Supported: unsupported protocol version"
== bad header
"HTTP/1.1 400 Bad Request"
"Content-Type: text/plain; charset=utf-8"
"Connection: close"
""
"400 Bad Request"
== lf only
"HTTP/1.0 200 OK"
"Date: <date>"
"Content-Length: 11"
"Content-Type: text/plain; charset=utf-8"
""
"plain text\n"

"""#

private let hc5Source = #"""
package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
)

var addr string

func say(name string) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%s [%s] id=%q rest=%q", name, r.Pattern, r.PathValue("id"), r.PathValue("rest"))
	}
}

func show(method, path, host string) {
	req, _ := http.NewRequest(method, "http://"+addr+path, nil)
	if host != "" {
		req.Host = host
	}
	client := &http.Client{CheckRedirect: func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Println(method, path, "error:", err)
		return
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Printf("%-6s %-22s %-8s -> %d %q loc=%q allow=%q\n", method, path, host, resp.StatusCode, strings.TrimSpace(string(body)), resp.Header.Get("Location"), resp.Header.Get("Allow"))
}

func conflict(mux *http.ServeMux, pattern string) {
	defer func() {
		if e := recover(); e != nil {
			text := fmt.Sprint(e)
			for strings.Contains(text, "(registered at ") {
				i := strings.Index(text, "(registered at ")
				j := strings.Index(text[i:], ")")
				text = text[:i] + "(at X" + text[i+j:]
			}
			fmt.Println("panic:", text)
		}
	}()
	mux.HandleFunc(pattern, say("never"))
	fmt.Println("registered", pattern)
}

func main() {
	port := "18085"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	addr = "127.0.0.1:" + port

	mux := http.NewServeMux()
	mux.HandleFunc("/", say("root"))
	mux.HandleFunc("/exact", say("exact"))
	mux.HandleFunc("/tree/", say("tree"))
	mux.HandleFunc("/tree/deeper/", say("deeper"))
	mux.HandleFunc("/tree/deeper/leaf", say("leaf"))
	mux.HandleFunc("GET /items/{id}", say("get item"))
	mux.HandleFunc("POST /items/{id}", say("post item"))
	mux.HandleFunc("/items/{id}/parts/{part}", say("part"))
	mux.HandleFunc("GET /files/{rest...}", say("files"))
	mux.HandleFunc("/only/{$}", say("only"))
	mux.HandleFunc("example.com/hosted", say("hosted"))
	mux.HandleFunc("/hosted", say("any host"))
	mux.HandleFunc("GET /items/special", say("special"))

	conflict(mux, "/exact")
	conflict(mux, "/items/{id}/parts/{other}")
	conflict(mux, "GET /{a}/special")
	conflict(mux, "bad pattern{")
	conflict(mux, "/a/{b}/{b}")
	conflict(mux, "")

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Println("listen:", err)
		return
	}
	go http.Serve(ln, mux)

	show("GET", "/", "")
	show("GET", "/unknown", "")
	show("GET", "/exact", "")
	show("GET", "/exact/", "")
	show("GET", "/tree", "")
	show("GET", "/tree/", "")
	show("GET", "/tree/x/y", "")
	show("GET", "/tree/deeper/x", "")
	show("GET", "/tree/deeper/leaf", "")
	show("GET", "/items/42", "")
	show("HEAD", "/items/42", "")
	show("POST", "/items/42", "")
	show("DELETE", "/items/42", "")
	show("GET", "/items/special", "")
	show("GET", "/items/a%2Fb", "")
	show("GET", "/items/42/parts/7", "")
	show("GET", "/files/a/b/c.txt", "")
	show("GET", "/files/", "")
	show("POST", "/files/a", "")
	show("GET", "/only/", "")
	show("GET", "/only/more", "")
	show("GET", "/only", "")
	show("GET", "/hosted", "")
	show("GET", "/hosted", "example.com")
	show("GET", "/hosted", "example.com:8080")
	show("GET", "/a//b/../c", "")
	show("GET", "/tree/./x", "")
}
"""#

private let hc5Expected = #"""
panic: pattern "/exact" (at X) conflicts with pattern "/exact" (at X):
/exact matches the same requests as /exact
panic: pattern "/items/{id}/parts/{other}" (at X) conflicts with pattern "/items/{id}/parts/{part}" (at X):
/items/{id}/parts/{other} matches the same requests as /items/{id}/parts/{part}
panic: pattern "GET /{a}/special" (at X) conflicts with pattern "/tree/" (at X):
GET /{a}/special and /tree/ both match some paths, like "/tree/special".
But neither is more specific than the other.
GET /{a}/special matches "/a/special", but /tree/ doesn't.
/tree/ matches "/tree/", but GET /{a}/special doesn't.
panic: parsing "bad pattern{": at offset 4: host/path missing /
panic: parsing "/a/{b}/{b}": at offset 7: duplicate wildcard name "b"
panic: http: invalid pattern
GET    /                               -> 200 "root [/] id=\"\" rest=\"\"" loc="" allow=""
GET    /unknown                        -> 200 "root [/] id=\"\" rest=\"\"" loc="" allow=""
GET    /exact                          -> 200 "exact [/exact] id=\"\" rest=\"\"" loc="" allow=""
GET    /exact/                         -> 200 "root [/] id=\"\" rest=\"\"" loc="" allow=""
GET    /tree                           -> 301 "<a href=\"/tree/\">Moved Permanently</a>." loc="/tree/" allow=""
GET    /tree/                          -> 200 "tree [/tree/] id=\"\" rest=\"\"" loc="" allow=""
GET    /tree/x/y                       -> 200 "tree [/tree/] id=\"\" rest=\"\"" loc="" allow=""
GET    /tree/deeper/x                  -> 200 "deeper [/tree/deeper/] id=\"\" rest=\"\"" loc="" allow=""
GET    /tree/deeper/leaf               -> 200 "leaf [/tree/deeper/leaf] id=\"\" rest=\"\"" loc="" allow=""
GET    /items/42                       -> 200 "get item [GET /items/{id}] id=\"42\" rest=\"\"" loc="" allow=""
HEAD   /items/42                       -> 200 "" loc="" allow=""
POST   /items/42                       -> 200 "post item [POST /items/{id}] id=\"42\" rest=\"\"" loc="" allow=""
DELETE /items/42                       -> 200 "root [/] id=\"\" rest=\"\"" loc="" allow=""
GET    /items/special                  -> 200 "special [GET /items/special] id=\"\" rest=\"\"" loc="" allow=""
GET    /items/a%2Fb                    -> 200 "get item [GET /items/{id}] id=\"a/b\" rest=\"\"" loc="" allow=""
GET    /items/42/parts/7               -> 200 "part [/items/{id}/parts/{part}] id=\"42\" rest=\"\"" loc="" allow=""
GET    /files/a/b/c.txt                -> 200 "files [GET /files/{rest...}] id=\"\" rest=\"a/b/c.txt\"" loc="" allow=""
GET    /files/                         -> 200 "files [GET /files/{rest...}] id=\"\" rest=\"\"" loc="" allow=""
POST   /files/a                        -> 200 "root [/] id=\"\" rest=\"\"" loc="" allow=""
GET    /only/                          -> 200 "only [/only/{$}] id=\"\" rest=\"\"" loc="" allow=""
GET    /only/more                      -> 200 "root [/] id=\"\" rest=\"\"" loc="" allow=""
GET    /only                           -> 301 "<a href=\"/only/\">Moved Permanently</a>." loc="/only/" allow=""
GET    /hosted                         -> 200 "any host [/hosted] id=\"\" rest=\"\"" loc="" allow=""
GET    /hosted                example.com -> 200 "hosted [example.com/hosted] id=\"\" rest=\"\"" loc="" allow=""
GET    /hosted                example.com:8080 -> 200 "hosted [example.com/hosted] id=\"\" rest=\"\"" loc="" allow=""
GET    /a//b/../c                      -> 301 "<a href=\"/a/c\">Moved Permanently</a>." loc="/a/c" allow=""
GET    /tree/./x                       -> 301 "<a href=\"/tree/x\">Moved Permanently</a>." loc="/tree/x" allow=""

"""#

private let hc6Source = #"""
package main

import (
	"errors"
	"fmt"
	"io"
	"net"
	web "net/http"
	"net/url"
	"os"
	"strings"

	"example/hc6/api"
)

type handler = web.Handler

func main() {
	port := "18086"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	addr := "127.0.0.1:" + port

	type route struct {
		pattern string
		handler handler
	}
	routes := []route{
		route{pattern: "/api/", handler: web.StripPrefix("/api", api.Tag("api")(api.Routes()))},
		route{pattern: "/plain", handler: web.HandlerFunc(func(w web.ResponseWriter, r *web.Request) {
			io.WriteString(w, "plain\n")
		})},
	}
	for _, r := range routes {
		web.Handle(r.pattern, r.handler)
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Println("listen:", err)
		return
	}
	go web.Serve(ln, nil)

	resp, err := web.Post("http://"+addr+"/api/echo?name=go&b=2&a=1", "text/plain", strings.NewReader("data"))
	if err != nil {
		fmt.Println("post:", err)
		return
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Printf("%d %q %q\n", resp.StatusCode, body, resp.Header.Get("X-Tag"))

	form := url.Values{}
	form.Set("name", "form value")
	form.Add("k", "a&b")
	resp, err = web.PostForm("http://"+addr+"/api/echo", form)
	if err != nil {
		fmt.Println("postform:", err)
		return
	}
	body, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Printf("%d %q\n", resp.StatusCode, body)

	resp, err = web.Get("http://" + addr + "/plain")
	if err != nil {
		fmt.Println("get:", err)
		return
	}
	body, _ = io.ReadAll(resp.Body)
	fmt.Printf("%d %q %T %v\n", resp.StatusCode, body, resp, resp.Body.Close())

	// Errors of the client.
	_, err = web.Get("http://127.0.0.1:1/")
	var uerr *url.Error
	fmt.Println(err, errors.As(err, &uerr))
	_, err = web.Get("ftp://example.com/")
	fmt.Println(err)
	_, err = web.Get("/relative")
	fmt.Println(err)
	u, err := url.Parse("http://user:pw@example.com:8080/a%20b/c?x=1&y=2#frag")
	fmt.Println(u.Scheme, u.Host, u.Hostname(), u.Port(), u.Path, u.RawQuery, u.Fragment, u.User.Username(), err)
	fmt.Println(u.String(), u.Query()["y"], url.QueryEscape("a b&c=d/é"), url.PathEscape("a b/c"))
	fmt.Println(web.CanonicalHeaderKey("x-forwarded-for"), web.DetectContentType([]byte("<!DOCTYPE html><html>")), web.DetectContentType([]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}))
}
"""#

private let hc6APISource = #"""
// Package api is a second package of the module that uses net/http.
package api

import (
	"fmt"
	stdio "io"
	web "net/http"
	"net/url"
)

// Middleware is another name for the usual shape.
type Middleware = func(web.Handler) web.Handler

// Tag sets a header on every response.
func Tag(value string) Middleware {
	return func(next web.Handler) web.Handler {
		return web.HandlerFunc(func(w web.ResponseWriter, r *web.Request) {
			w.Header().Set("X-Tag", value)
			next.ServeHTTP(w, r)
		})
	}
}

// Echo answers with the query and the body of the request.
func Echo(w web.ResponseWriter, r *web.Request) {
	var values url.Values = r.URL.Query()
	body, _ := stdio.ReadAll(r.Body)
	var out stdio.Writer = w
	fmt.Fprintf(out, "name=%s body=%s encoded=%s\n", values.Get("name"), body, values.Encode())
}

// Routes returns the handler of the package.
func Routes() *web.ServeMux {
	mux := web.NewServeMux()
	mux.HandleFunc("/echo", Echo)
	return mux
}
"""#

private let hc6Expected = #"""
200 "name=go body=data encoded=a=1&b=2&name=go\n" "api"
200 "name= body=k=a%26b&name=form+value encoded=\n"
200 "plain\n" *http.Response <nil>
Get "http://127.0.0.1:1/": dial tcp 127.0.0.1:1: connect: connection refused true
Get "ftp://example.com/": unsupported protocol scheme "ftp"
Get "/relative": unsupported protocol scheme ""
http example.com:8080 example.com 8080 /a b/c x=1&y=2 frag user <nil>
http://user:pw@example.com:8080/a%20b/c?x=1&y=2#frag [2] a+b%26c%3Dd%2F%C3%A9 a%20b%2Fc
X-Forwarded-For text/html; charset=utf-8 image/png

"""#

private let hc7Source = #"""
package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
)

// get asks until the server, which a goroutine is starting, listens.
func get(url string) {
	for try := 0; try < 2000; try++ {
		resp, err := http.Get(url)
		if err != nil {
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		fmt.Printf("%s %q\n", resp.Status, body)
		return
	}
	fmt.Println("no answer")
}

func main() {
	port := 18087
	if len(os.Args) > 1 {
		port, _ = strconv.Atoi(os.Args[1])
	}
	first := "127.0.0.1:" + strconv.Itoa(port)
	second := "127.0.0.1:" + strconv.Itoa(port+1000)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "default mux", r.URL.Path)
	})
	go http.ListenAndServe(first, nil)
	get("http://" + first + "/a")

	mux := http.NewServeMux()
	mux.HandleFunc("/stream", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "one ")
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		fmt.Fprint(w, "two")
	})
	mux.HandleFunc("/head", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "a body that HEAD does not get")
	})
	srv := &http.Server{Addr: second, Handler: mux}
	go srv.ListenAndServe()
	get("http://" + second + "/stream")
	get("http://" + second + "/missing")

	resp, err := http.Head("http://" + second + "/head")
	if err != nil {
		fmt.Println("head:", err)
		return
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Println(resp.Status, resp.ContentLength, len(body), resp.Header.Get("Content-Type"))

	// A second listener on a port that is taken fails.
	fmt.Println(http.ListenAndServe(first, nil) != nil)
}
"""#

private let hc7Expected = #"""
200 OK "default mux /a\n"
200 OK "one two"
404 Not Found "404 page not found\n"
200 OK 30 0 text/plain; charset=utf-8
true

"""#

private let middlewareSource = #"""
package main

import (
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

type Route struct {
	Pattern string `json:"pattern"`
	Hits    uint32
}

type stats struct {
	sync.Mutex
	routes map[string]*Route
}

func (s *stats) hit(pattern string) {
	s.Lock()
	defer s.Unlock()
	if r, ok := s.routes[pattern]; ok {
		r.Hits++
		return
	}
	s.routes[pattern] = &Route{Pattern: pattern, Hits: 1}
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

type Middleware func(http.Handler) http.Handler

func chain(h http.Handler, layers ...Middleware) http.Handler {
	for i := len(layers) - 1; i >= 0; i-- {
		h = layers[i](h)
	}
	return h
}

func counting(s *stats) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(sw, r)
			s.hit(fmt.Sprint(r.Method, " ", r.URL.Path, " ", sw.status))
		})
	}
}

func tagging(name string) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Add("X-Via", name)
			next.ServeHTTP(w, r)
		})
	}
}

func fetch(method, url, body string) (int, string, string) {
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		return 0, "", err.Error()
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", err.Error()
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, strings.Join(resp.Header.Values("X-Via"), ","), string(data)
}

func main() {
	s := &stats{routes: map[string]*Route{}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /items/{id}", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "item %s", r.PathValue("id"))
	})
	mux.HandleFunc("POST /echo", func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(strings.ToUpper(string(data))))
	})
	mux.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(20 * time.Millisecond)
		io.WriteString(w, "slow")
	})
	const addr = "127.0.0.1:18973"
	go http.ListenAndServe(addr, chain(mux, tagging("outer"), counting(s), tagging("inner")))
	time.Sleep(100 * time.Millisecond)

	base := "http://" + addr
	fmt.Println(fetch("GET", base+"/items/42", ""))
	fmt.Println(fetch("POST", base+"/echo", "hello"))
	fmt.Println(fetch("DELETE", base+"/items/42", ""))
	code, via, body := fetch("GET", base+"/missing", "")
	fmt.Println(code, via, strings.TrimSpace(body))

	var wg sync.WaitGroup
	for range 3 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			fetch("GET", base+"/slow", "")
		}()
	}
	wg.Wait()

	var keys []string
	for k := range s.routes {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	for _, k := range keys {
		switch r := any(s.routes[k]).(type) {
		case *Route:
			fmt.Printf("%-24s %d %T\n", r.Pattern, r.Hits, r.Hits)
		}
	}
}
"""#

private let middlewareExpected = #"""
200 outer,inner item 42
201 outer,inner HELLO
405 outer,inner Method Not Allowed

404 outer,inner 404 page not found
DELETE /items/42 405     1 uint32
GET /items/42 200        1 uint32
GET /missing 404         1 uint32
GET /slow 200            3 uint32
POST /echo 201           1 uint32

"""#
