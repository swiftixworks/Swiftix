/// `http.RoundTripper` and `http.Transport`, and `httputil.ReverseProxy`,
/// in front of a server on the loopback interface.
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
