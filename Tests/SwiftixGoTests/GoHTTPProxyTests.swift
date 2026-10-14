/// `http.RoundTripper` and `http.Transport`, `httputil.ReverseProxy`, and
/// `http.FileServer`, with servers on the loopback interface.
///
/// What each program prints is what Go 1.24.5 printed for it; the ports the
/// system chose are printed as names.

import Testing

@testable import Swiftix
@testable import SwiftixGo
@testable import SwiftixGoRuntime

@Suite("Go HTTP transports and reverse proxies")
struct GoHTTPProxyTests {
    /// Runs `source` as a process of a kernel that has a loopback
    /// interface, and returns what it printed on standard output.
    private func run(_ source: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
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
        var failure: (any Error)?
        kernel.spawn("proxy") { context in
            for path in ["/stdin", "/stdout", "/stderr"] {
                _ = context.open(path, create: true, truncate: true)
            }
            do {
                _ = try GoVirtualMachine(maximumInstructions: 50_000_000).run(
                    executable, eventLoop: loop, processContext: context, arguments: ["proxy"]
                ) { output += $0 }
            } catch {
                failure = error
            }
            context.exit(0)
        }
        loop.runUntilIdle()
        if let failure { throw failure }
        return output
    }

    /// A `Client` sends through its `Transport`: a `RoundTripper` of the program around `DefaultTransport`, a `Transport` with a `DialContext`, one that answers itself, and one that fails, whose error the client wraps as Go's does.
    @Test func clientsSendThroughRoundTrippers() throws {
        #expect(try run(roundTripSource) == roundTripExpected)
    }

    /// `httputil.ReverseProxy`: `NewSingleHostReverseProxy` joins the paths, drops the hop-by-hop headers, adds `X-Forwarded-For`; `Rewrite` with `SetURL` and `SetXForwarded`; `ModifyResponse`; and an upstream that refuses, answered by an `ErrorHandler` or with Go's 502.
    @Test func reverseProxiesForwardAsGosDo() throws {
        #expect(try run(proxySource) == proxyExpected)
    }

    /// `http.FileServer` over `http.Dir` and over an `fs.FS`, `ServeFile`,
    /// and `ServeContent`: index files, directory listings, the redirects
    /// to and from a slash, ranges, and the conditional headers, with Go's
    /// headers and bodies.
    @Test func filesAreServedAsGoServesThem() throws {
        #expect(try run(fileServerSource) == fileServerExpected)
    }
}

private let roundTripSource = #"""
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
)

type logging struct {
	next http.RoundTripper
	seen []string
}

func (l *logging) RoundTrip(req *http.Request) (*http.Response, error) {
	l.seen = append(l.seen, req.Method+" "+req.URL.Path)
	req.Header.Set("X-Via", "logging")
	return l.next.RoundTrip(req)
}

type fixed struct{}

func (fixed) RoundTrip(req *http.Request) (*http.Response, error) {
	return &http.Response{StatusCode: 418, Status: "418 I'm a teapot", Body: io.NopCloser(strings.NewReader("short and stout")), Header: http.Header{}, Request: req}, nil
}

type broken struct{}

func (broken) RoundTrip(req *http.Request) (*http.Response, error) {
	return nil, errors.New("no route")
}

func main() {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/hello", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "hi via=%s", r.Header.Get("X-Via"))
	})
	go http.Serve(ln, mux)
	base := "http://" + ln.Addr().String()

	lt := &logging{next: http.DefaultTransport}
	c := &http.Client{Transport: lt}
	resp, err := c.Get(base + "/hello")
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Println(resp.StatusCode, string(body), err, lt.seen)

	dials := 0
	t := &http.Transport{DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
		dials++
		var d net.Dialer
		_ = d
		return net.Dial(network, addr)
	}}
	req, _ := http.NewRequest("GET", base+"/hello", nil)
	resp, err = t.RoundTrip(req)
	body, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Println(resp.StatusCode, string(body), err, dials)

	resp, err = (&http.Client{Transport: fixed{}}).Get("http://example.invalid/x")
	body, _ = io.ReadAll(resp.Body)
	fmt.Println(resp.StatusCode, resp.Status, string(body), err)
	_, err = (&http.Client{Transport: broken{}}).Get("http://example.invalid/x")
	fmt.Println(err)
	var urlErr interface{ Unwrap() error }
	fmt.Println(errors.As(err, &urlErr))
	_, ok := http.DefaultTransport.(*http.Transport)
	fmt.Println(ok)
}
"""#

private let roundTripExpected = #"""
200 hi via=logging <nil> [GET /hello]
200 hi via= <nil> 1
418 418 I'm a teapot short and stout <nil>
Get "http://example.invalid/x": no route
true
true

"""#

private let proxySource = #"""
package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"sort"
	"strings"
)

func serve(handler http.Handler) string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	go http.Serve(ln, handler)
	return "http://" + ln.Addr().String()
}

func main() {
	backend := serve(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var keys []string
		for k := range r.Header {
			if k == "X-Forwarded-For" || strings.HasPrefix(k, "X-") || k == "Connection" || k == "Keep-Alive" {
				keys = append(keys, k+"="+strings.Join(r.Header[k], ","))
			}
		}
		sort.Strings(keys)
		body, _ := io.ReadAll(r.Body)
		w.Header().Set("X-Backend", "one")
		w.Header().Set("Connection", "close, X-Drop")
		w.Header().Set("X-Drop", "secret")
		w.WriteHeader(201)
		fmt.Fprintf(w, "%s %s host=%s body=%q %v", r.Method, r.URL.String(), r.Host, body, keys)
	}))
	target, _ := url.Parse(backend + "/base")
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorLog = log.New(os.Stdout, "proxy: ", 0)
	front := serve(proxy)

	req, _ := http.NewRequest("POST", front+"/api/items?x=1", strings.NewReader("payload"))
	req.Header.Set("Connection", "Keep-Alive, X-Hop")
	req.Header.Set("X-Hop", "drop me")
	req.Header.Set("X-Keep", "kept")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		panic(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Println(resp.StatusCode, resp.Header.Get("X-Backend"), resp.Header.Get("X-Drop") == "")
	fmt.Println(strings.Replace(string(body), strings.TrimPrefix(front, "http://"), "FRONT", -1))

	rewrite := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			pr.SetXForwarded()
			pr.Out.Header.Set("X-Rewritten", "yes")
		},
		ModifyResponse: func(r *http.Response) error {
			r.Header.Set("X-Modified", r.Status)
			return nil
		},
	}
	front2 := serve(rewrite)
	resp, _ = http.Get(front2 + "/r")
	body, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	out := strings.Replace(string(body), strings.TrimPrefix(front2, "http://"), "FRONT", -1)
	out = strings.Replace(out, strings.TrimPrefix(backend, "http://"), "BACKEND", -1)
	fmt.Println(resp.StatusCode, resp.Header.Get("X-Modified"), out)

	down, _ := url.Parse("http://127.0.0.1:1")
	bad := httputil.NewSingleHostReverseProxy(down)
	bad.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		w.WriteHeader(http.StatusBadGateway)
		fmt.Fprint(w, "upstream down")
	}
	front3 := serve(bad)
	resp, _ = http.Get(front3 + "/x")
	body, _ = io.ReadAll(resp.Body)
	fmt.Println(resp.StatusCode, string(body))
	quiet := httputil.NewSingleHostReverseProxy(down)
	quiet.ErrorLog = log.New(io.Discard, "", 0)
	front4 := serve(quiet)
	resp, _ = http.Get(front4 + "/y")
	body, _ = io.ReadAll(resp.Body)
	fmt.Printf("%d %q\n", resp.StatusCode, body)
}
"""#

private let proxyExpected = #"""
201 one false
POST /base/api/items?x=1 host=FRONT body="payload" [X-Forwarded-For=127.0.0.1 X-Keep=kept]
201 201 Created GET /base/r host=BACKEND body="" [X-Forwarded-For=127.0.0.1 X-Forwarded-Host=FRONT X-Forwarded-Proto=http X-Rewritten=yes]
502 upstream down
502 ""

"""#

private let fileServerSource = #"""
package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

func get(base, path string, header ...string) {
	req, _ := http.NewRequest("GET", base+path, nil)
	for i := 0; i+1 < len(header); i += 2 {
		req.Header.Set(header[i], header[i+1])
	}
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Println(path, "error:", err)
		return
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	var keys []string
	for k := range resp.Header {
		switch k {
		case "Date", "Last-Modified":
			continue
		}
		keys = append(keys, k+"="+strings.Join(resp.Header[k], ","))
	}
	sort.Strings(keys)
	fmt.Printf("%s %d %v\n%s\n--\n", path, resp.StatusCode, keys, body)
}

func main() {
	os.MkdirAll("www/css", 0o755)
	os.MkdirAll("www/docs", 0o755)
	os.WriteFile("www/index.html", []byte("<h1>home</h1>\n"), 0o644)
	os.WriteFile("www/css/site.css", []byte("body { margin: 0 }\n"), 0o644)
	os.WriteFile("www/docs/a.txt", []byte("0123456789"), 0o644)
	os.WriteFile("www/docs/b&c.json", []byte(`{"ok":true}`), 0o644)
	os.WriteFile("www/plain", []byte("no extension here"), 0o644)
	stamp := time.Date(2024, 3, 1, 12, 0, 0, 0, time.UTC)

	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	mux := http.NewServeMux()
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("www"))))
	mux.Handle("/fs/", http.StripPrefix("/fs", http.FileServerFS(os.DirFS("www"))))
	mux.HandleFunc("/one", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "www/docs/a.txt")
	})
	mux.HandleFunc("/content", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", `"v1"`)
		http.ServeContent(w, r, "data.json", stamp, strings.NewReader(`{"hello":"world"}`))
	})
	go http.Serve(ln, mux)
	base := "http://" + ln.Addr().String()

	get(base, "/static/")
	get(base, "/static/index.html")
	get(base, "/static/css/site.css")
	get(base, "/static/docs/")
	get(base, "/static/docs")
	get(base, "/static/plain")
	get(base, "/static/missing.html")
	get(base, "/static/docs/a.txt", "Range", "bytes=2-5")
	get(base, "/static/docs/a.txt", "Range", "bytes=-3")
	get(base, "/static/docs/a.txt", "Range", "bytes=20-30")
	get(base, "/fs/css/site.css")
	get(base, "/fs/docs/")
	get(base, "/one")
	get(base, "/content")
	get(base, "/content", "If-None-Match", `"v1"`)
	get(base, "/content", "If-Modified-Since", stamp.Add(time.Hour).Format(http.TimeFormat))
	get(base, "/content", "If-Match", `"v2"`)
	get(base, "/static/../secret")
	os.RemoveAll("www")
}
"""#

private let fileServerExpected = #"""
/static/ 200 [Accept-Ranges=bytes Content-Length=14 Content-Type=text/html; charset=utf-8]
<h1>home</h1>

--
/static/index.html 301 [Content-Length=0 Location=./]

--
/static/css/site.css 200 [Accept-Ranges=bytes Content-Length=19 Content-Type=text/css; charset=utf-8]
body { margin: 0 }

--
/static/docs/ 200 [Content-Length=143 Content-Type=text/html; charset=utf-8]
<!doctype html>
<meta name="viewport" content="width=device-width">
<pre>
<a href="a.txt">a.txt</a>
<a href="b&c.json">b&amp;c.json</a>
</pre>

--
/static/docs 301 [Content-Length=0 Location=docs/]

--
/static/plain 200 [Accept-Ranges=bytes Content-Length=17 Content-Type=text/plain; charset=utf-8]
no extension here
--
/static/missing.html 404 [Content-Length=19 Content-Type=text/plain; charset=utf-8 X-Content-Type-Options=nosniff]
404 page not found

--
/static/docs/a.txt 206 [Accept-Ranges=bytes Content-Length=4 Content-Range=bytes 2-5/10 Content-Type=text/plain; charset=utf-8]
2345
--
/static/docs/a.txt 206 [Accept-Ranges=bytes Content-Length=3 Content-Range=bytes 7-9/10 Content-Type=text/plain; charset=utf-8]
789
--
/static/docs/a.txt 416 [Content-Length=33 Content-Range=bytes */10 Content-Type=text/plain; charset=utf-8 X-Content-Type-Options=nosniff]
invalid range: failed to overlap

--
/fs/css/site.css 200 [Accept-Ranges=bytes Content-Length=19 Content-Type=text/css; charset=utf-8]
body { margin: 0 }

--
/fs/docs/ 200 [Content-Length=143 Content-Type=text/html; charset=utf-8]
<!doctype html>
<meta name="viewport" content="width=device-width">
<pre>
<a href="a.txt">a.txt</a>
<a href="b&c.json">b&amp;c.json</a>
</pre>

--
/one 200 [Accept-Ranges=bytes Content-Length=10 Content-Type=text/plain; charset=utf-8]
0123456789
--
/content 200 [Accept-Ranges=bytes Content-Length=17 Content-Type=application/json Etag="v1"]
{"hello":"world"}
--
/content 304 [Etag="v1"]

--
/content 304 [Etag="v1"]

--
/content 412 [Content-Length=0 Etag="v1"]

--
/static/../secret 301 [Content-Length=42 Content-Type=text/html; charset=utf-8 Location=/secret]
<a href="/secret">Moved Permanently</a>.


--

"""#
