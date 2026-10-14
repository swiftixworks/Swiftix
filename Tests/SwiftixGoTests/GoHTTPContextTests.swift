/// `net/http` with contexts, timeouts, and shutdown, and the network
/// handles under it.
///
/// Each program starts a server on the loopback interface of its own
/// kernel, talks to it, and prints what it sees; the expected text is what
/// the same program printed under Go 1.24.5. Durations are of the logical
/// clock, which the synchronous run advances while every goroutine waits,
/// so a timeout of seconds costs no wall time and the elapsed times the
/// programs print are exact here and rounded under Go.
///
/// Concurrency: every test builds its own `EventLoop` + `Kernel` and drives
/// it on the calling executor; nothing is shared between tests.

import Testing

@testable import Swiftix
@testable import SwiftixGo
@testable import SwiftixGoRuntime

@Suite("Go net/http contexts and timeouts")
struct GoHTTPContextTests {

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
        kernel.spawn("server") { context in
            for path in ["/stdin", "/stdout", "/stderr"] {
                _ = context.open(path, create: true, truncate: true)
            }
            do {
                _ = try GoVirtualMachine(maximumInstructions: 20_000_000).run(
                    executable, eventLoop: loop, processContext: context,
                    arguments: ["server"]
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

    private func expectGo(_ source: String, _ expected: String) throws {
        let difference = firstDifference(try run(source), from: expected)
        #expect(difference == nil, "\(difference ?? "")")
    }

    /// `r.Context()` is cancelled when the handler returns and when the
    /// client goes away; `WithContext`, `Clone`, and `ServerContextKey`;
    /// `NewRequestWithContext` with a deadline, a cancel, and a context
    /// that is done before the request is sent, and the errors Go gives.
    @Test func requestsCarryContexts() throws {
        try expectGo(contextSource, contextExpected)
    }

    /// `ReadTimeout`, `ReadHeaderTimeout`, `WriteTimeout`, and `IdleTimeout`
    /// as a client sees them, a body read that fails at `ReadTimeout` in a
    /// handler that still answers, and `Client.Timeout` and a context's
    /// deadline, cancel, and cause, while awaiting the header and while
    /// reading the body.
    @Test func serversAndClientsTimeOut() throws {
        try expectGo(timeoutSource, timeoutExpected)
    }

    /// `Shutdown` closes the listener and the idle connection, waits for
    /// the active one, runs `RegisterOnShutdown`'s functions, and gives up
    /// when its context does; `Close` ends what is left; `ListenAndServe`
    /// and `Serve` return `ErrServerClosed`; the `ConnState` hook sees each
    /// state.
    @Test func serversShutDownAndClose() throws {
        try expectGo(shutdownSource, shutdownExpected)
    }

    /// `TimeoutHandler` sends what a handler wrote in time, and otherwise
    /// 503 with its message or its page; the handler's context is done and
    /// its writes fail with `ErrHandlerTimeout`.
    @Test func timeoutHandlersAnswerForSlowHandlers() throws {
        try expectGo(timeoutHandlerSource, timeoutHandlerExpected)
    }

    /// `Close` of a listener wakes the goroutine in `Accept`, and `Close`
    /// of a connection the one in `Read`, with Go's error; both fail after.
    @Test func closingAHandleWakesItsWaiter() throws {
        try expectGo(netCloseSource, netCloseExpected)
    }

    /// A server and a client are linked with the part of `context` they
    /// reach, which is `Background` and its errors, and not with the
    /// contexts that cancel.
    @Test func aServerIsNotLinkedWithCancellingContexts() throws {
        func names(_ source: String) throws -> [String] {
            try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: source)])
                .functions.map(\.name)
        }
        let server = try names(
            """
            package main
            import "net/http"
            func main() {
                http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {})
                http.ListenAndServe(":8080", nil)
            }
            """)
        let client = try names(
            """
            package main
            import "net/http"
            func main() { http.Get("http://127.0.0.1:8080/") }
            """)
        for linked in [server, client] {
            #expect(linked.contains("context.Background"))
            #expect(!linked.contains { $0.hasPrefix("*context.cancelCtx.") })
            #expect(!linked.contains { $0.hasPrefix("*context.timerCtx.") })
            #expect(!linked.contains("context.WithCancel"))
        }
        #expect(server.contains("*net/http.Server.Shutdown"))
    }
}


private let contextSource = #"""
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"time"
)

type key string

func main() {
	port := "18181"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	addr := "127.0.0.1:" + port
	base := "http://" + addr

	saved := make(chan context.Context, 1)
	gone := make(chan string, 1)
	mux := http.NewServeMux()
	mux.HandleFunc("/keep", func(w http.ResponseWriter, r *http.Request) {
		saved <- r.Context()
		fmt.Println("in handler:", r.Context().Err())
		fmt.Fprintln(w, "kept")
	})
	mux.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
			gone <- "client gone: " + r.Context().Err().Error()
		case <-time.After(5 * time.Second):
			gone <- "finished"
			fmt.Fprintln(w, "slow")
		}
	})
	mux.HandleFunc("/value", func(w http.ResponseWriter, r *http.Request) {
		r2 := r.WithContext(context.WithValue(r.Context(), key("user"), "ann"))
		fmt.Fprintln(w, r2.Context().Value(key("user")), r.Context().Value(key("user")), r2.URL == r.URL, r2.Method)
		r3 := r2.Clone(context.Background())
		r3.Header.Set("X-A", "changed")
		r3.URL.Path = "/other"
		fmt.Fprintln(w, r3.Context().Value(key("user")), r.Header.Get("X-A"), r3.Header.Get("X-A"), r.URL.Path, r3.URL.Path)
		_, isSrv := r.Context().Value(http.ServerContextKey).(*http.Server)
		fmt.Fprintln(w, isSrv)
	})
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Println(err)
		return
	}
	go http.Serve(ln, mux)

	resp, err := http.Get(base + "/keep")
	if err != nil {
		fmt.Println(err)
		return
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Printf("%q\n", b)
	ctx := <-saved
	<-ctx.Done()
	fmt.Println("after handler:", ctx.Err())

	// A client that gives up.
	cctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	req, _ := http.NewRequestWithContext(cctx, "GET", base+"/slow", nil)
	start := time.Now()
	_, err = http.DefaultClient.Do(req)
	cancel()
	fmt.Println(err)
	var ue *url.Error
	fmt.Println(errors.As(err, &ue), errors.Is(err, context.DeadlineExceeded), ue.Timeout(), time.Since(start) < time.Second)
	fmt.Println(<-gone)

	// Cancelled by hand.
	cctx2, cancel2 := context.WithCancel(context.Background())
	req2, _ := http.NewRequestWithContext(cctx2, "GET", base+"/slow", nil)
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel2()
	}()
	_, err = http.DefaultClient.Do(req2)
	fmt.Println(err, errors.Is(err, context.Canceled))
	fmt.Println(<-gone)

	// Cancelled before it is sent.
	cctx3, cancel3 := context.WithCancel(context.Background())
	cancel3()
	req3, _ := http.NewRequestWithContext(cctx3, "GET", base+"/keep", nil)
	_, err = http.DefaultClient.Do(req3)
	fmt.Println(err)

	req4, _ := http.NewRequest("GET", base+"/value", nil)
	req4.Header.Set("X-A", "orig")
	fmt.Println(req4.Context() == context.Background())
	resp, err = http.DefaultClient.Do(req4)
	if err != nil {
		fmt.Println(err)
		return
	}
	b, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Printf("%s", b)

	_, err = http.NewRequestWithContext(nil, "GET", base, nil)
	fmt.Println(err)
	func() {
		defer func() { fmt.Println("recovered:", recover()) }()
		req4.WithContext(nil)
	}()
}

"""#

private let contextExpected = #"""
in handler: <nil>
"kept\n"
after handler: context canceled
Get "http://127.0.0.1:18181/slow": context deadline exceeded
true true true true
client gone: context canceled
Get "http://127.0.0.1:18181/slow": context canceled true
client gone: context canceled
Get "http://127.0.0.1:18181/keep": context canceled
true
ann <nil> true GET
<nil> orig changed /value /other
true
net/http: nil Context
recovered: nil context

"""#

private let timeoutSource = #"""
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

var handled = make(chan string, 10)

// raw sends request after pause on a connection of its own, and prints the
// response without its Date, and how long it took to end.
func raw(addr, request string, pause time.Duration) {
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		fmt.Println("dial:", err)
		return
	}
	start := time.Now()
	time.Sleep(pause)
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
	var lines []string
	for _, line := range strings.Split(string(all), "\r\n") {
		if !strings.HasPrefix(line, "Date: ") {
			lines = append(lines, line)
		}
	}
	fmt.Printf("%q after %v\n", strings.Join(lines, "|"), time.Since(start).Round(100*time.Millisecond))
}

// get sends a GET under ctx with c, and prints the response or the error.
func get(c *http.Client, ctx context.Context, url string) {
	start := time.Now()
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	resp, err := c.Do(req)
	if err != nil {
		var te interface{ Timeout() bool }
		fmt.Println(err, errors.As(err, &te) && te.Timeout(), errors.Is(err, context.DeadlineExceeded), time.Since(start).Round(100*time.Millisecond))
		return
	}
	b, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	var te interface{ Timeout() bool }
	fmt.Printf("%d %q %v %v %v %v\n", resp.StatusCode, b, err, errors.As(err, &te) && te.Timeout(), errors.Is(err, context.DeadlineExceeded), time.Since(start).Round(100*time.Millisecond))
}

func main() {
	port := "18282"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	addr := "127.0.0.1:" + port
	base := "http://" + addr
	mux := http.NewServeMux()
	mux.HandleFunc("/sleep", func(w http.ResponseWriter, r *http.Request) {
		d, _ := time.ParseDuration(r.URL.Query().Get("d"))
		time.Sleep(d)
		handled <- fmt.Sprint("sleep ", d, ": ", r.Context().Err())
		fmt.Fprintln(w, "slept", d)
	})
	mux.HandleFunc("/body", func(w http.ResponseWriter, r *http.Request) {
		b, err := io.ReadAll(r.Body)
		var te interface{ Timeout() bool }
		// Go's error names the addresses: "read tcp a->b: i/o timeout".
		fmt.Fprintln(w, len(b), strings.HasSuffix(err.Error(), ": i/o timeout") || err.Error() == "i/o timeout", errors.As(err, &te) && te.Timeout())
	})
	mux.HandleFunc("/drip", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "first")
		w.(http.Flusher).Flush()
		select {
		case <-r.Context().Done():
			handled <- "drip: " + r.Context().Err().Error()
		case <-time.After(2 * time.Second):
			handled <- "drip: done"
		}
		fmt.Fprintln(w, "second")
	})
	srv := &http.Server{
		Handler:           mux,
		ReadTimeout:       time.Second,
		ReadHeaderTimeout: 500 * time.Millisecond,
		WriteTimeout:      2 * time.Second,
		IdleTimeout:       3 * time.Second,
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Println(err)
		return
	}
	go srv.Serve(ln)

	fmt.Println("-- the server")
	// Longer than ReadTimeout and shorter than WriteTimeout: answered.
	raw(addr, "GET /sleep?d=1500ms HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 0)
	fmt.Println(<-handled)
	// Longer than WriteTimeout: the response is never sent.
	raw(addr, "GET /sleep?d=2500ms HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 0)
	fmt.Println(<-handled)
	// A header that comes after ReadHeaderTimeout, and one that never does.
	raw(addr, "GET /sleep?d=0s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 700*time.Millisecond)
	raw(addr, "", 0)
	// A body that stops coming: the handler's read fails at ReadTimeout.
	raw(addr, "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\nConnection: close\r\n\r\nabc", 0)
	// A connection kept open: closed after IdleTimeout.
	raw(addr, "GET /sleep?d=0s HTTP/1.1\r\nHost: x\r\n\r\n", 0)
	fmt.Println(<-handled)

	fmt.Println("-- the client")
	c := &http.Client{Timeout: 300 * time.Millisecond}
	get(c, context.Background(), base+"/sleep?d=1s")
	fmt.Println(<-handled)
	get(c, context.Background(), base+"/drip")
	fmt.Println(<-handled)
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	get(http.DefaultClient, ctx, base+"/drip")
	cancel()
	fmt.Println(<-handled)
	ctx, cancel = context.WithCancel(context.Background())
	time.AfterFunc(300*time.Millisecond, cancel)
	get(http.DefaultClient, ctx, base+"/drip")
	fmt.Println(<-handled)
	ctx, ccancel := context.WithCancelCause(context.Background())
	time.AfterFunc(300*time.Millisecond, func() { ccancel(errors.New("my cause")) })
	get(http.DefaultClient, ctx, base+"/drip")
	fmt.Println(<-handled)
	ctx, ccancel = context.WithCancelCause(context.Background())
	ccancel(errors.New("early cause"))
	get(http.DefaultClient, ctx, base+"/drip")
	// A deadline of the context sooner than the client's Timeout.
	ctx, cancel = context.WithTimeout(context.Background(), 100*time.Millisecond)
	get(c, ctx, base+"/sleep?d=1s")
	cancel()
	fmt.Println(<-handled)
}

"""#

private let timeoutExpected = #"""
-- the server
"HTTP/1.1 200 OK|Content-Length: 11|Content-Type: text/plain; charset=utf-8|Connection: close||slept 1.5s\n" after 1.5s
sleep 1.5s: <nil>
"" after 2.5s
sleep 2.5s: <nil>
"" after 700ms
"" after 500ms
"HTTP/1.1 200 OK|Content-Length: 12|Content-Type: text/plain; charset=utf-8|Connection: close||3 true true\n" after 1s
"HTTP/1.1 200 OK|Content-Length: 9|Content-Type: text/plain; charset=utf-8||slept 0s\n" after 3s
sleep 0s: <nil>
-- the client
Get "http://127.0.0.1:18282/sleep?d=1s": context deadline exceeded (Client.Timeout exceeded while awaiting headers) true true 300ms
sleep 1s: context canceled
200 "first\n" context deadline exceeded (Client.Timeout or context cancellation while reading body) true true 300ms
drip: context canceled
200 "first\n" context deadline exceeded true true 300ms
drip: context canceled
200 "first\n" context canceled false false 300ms
drip: context canceled
200 "first\n" my cause false false 300ms
drip: context canceled
Get "http://127.0.0.1:18282/drip": early cause false false 0s
Get "http://127.0.0.1:18282/sleep?d=1s": context deadline exceeded true true 100ms
sleep 1s: context canceled

"""#

private let shutdownSource = #"""
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	mu  sync.Mutex
	log []string
)

func note(s string) {
	mu.Lock()
	log = append(log, s)
	mu.Unlock()
	fmt.Println(s)
}

func get(base, path string) {
	resp, err := http.Get(base + path)
	if err != nil {
		note("get " + path + ": " + err.Error())
		return
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	note(fmt.Sprintf("get %s: %d %q close=%v", path, resp.StatusCode, b, resp.Close))
}

func main() {
	port := 18186
	if len(os.Args) > 1 {
		port, _ = strconv.Atoi(os.Args[1])
	}
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	base := "http://" + addr
	states := make(chan string, 100)
	stopped := make(chan bool, 1)
	srv := &http.Server{
		Addr: addr,
		ConnState: func(c net.Conn, s http.ConnState) {
			states <- s.String()
		},
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			d, _ := time.ParseDuration(r.URL.Query().Get("d"))
			select {
			case <-time.After(d):
				fmt.Fprintln(w, "done", d)
			case <-r.Context().Done():
				note("handler " + r.URL.Path + ": " + r.Context().Err().Error())
				stopped <- true
			}
		}),
	}
	srv.RegisterOnShutdown(func() { note("on shutdown") })
	served := make(chan error)
	go func() { served <- srv.ListenAndServe() }()
	time.Sleep(10 * time.Millisecond)

	// An idle connection that Shutdown closes.
	idle, err := net.Dial("tcp", addr)
	if err != nil {
		fmt.Println(err)
		return
	}
	idle.Write([]byte("GET /?d=0s HTTP/1.1\r\nHost: x\r\n\r\n"))
	buf := make([]byte, 4096)
	n, _ := idle.Read(buf)
	fmt.Println(strings.Split(string(buf[:n]), "\r\n")[0])

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		get(base, "/slow?d=300ms")
	}()
	time.Sleep(50 * time.Millisecond)
	start := time.Now()
	err = srv.Shutdown(context.Background())
	note(fmt.Sprintf("shutdown: %v after %v", err, time.Since(start).Round(100*time.Millisecond)))
	wg.Wait()
	err = <-served
	note(fmt.Sprint("serve: ", err, " ", errors.Is(err, http.ErrServerClosed)))
	n, err = idle.Read(buf)
	fmt.Println("idle read:", n, err)
	fmt.Println(srv.ListenAndServe())
	ln, _ := net.Listen("tcp", addr)
	fmt.Println(srv.Serve(ln))

	// A second server whose handler outlasts Shutdown's context.
	srv2 := &http.Server{Addr: addr, Handler: srv.Handler}
	go func() { served <- srv2.ListenAndServe() }()
	time.Sleep(10 * time.Millisecond)
	wg.Add(1)
	go func() {
		defer wg.Done()
		get(base, "/stuck?d=10s")
	}()
	time.Sleep(50 * time.Millisecond)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	err = srv2.Shutdown(ctx)
	cancel()
	note(fmt.Sprint("shutdown: ", err))
	note(fmt.Sprint("serve: ", <-served))
	err = srv2.Close()
	<-stopped
	note(fmt.Sprint("close: ", err))
	wg.Wait()
	close(states)
	var all []string
	for s := range states {
		all = append(all, s)
	}
	fmt.Println(strings.Join(all, " "))
}

"""#

private let shutdownExpected = #"""
HTTP/1.1 200 OK
on shutdown
get /slow?d=300ms: 200 "done 300ms\n" close=true
shutdown: <nil> after 300ms
serve: http: Server closed true
idle read: 0 EOF
http: Server closed
http: Server closed
shutdown: context deadline exceeded
serve: http: Server closed
handler /stuck: context canceled
close: <nil>
get /stuck?d=10s: Get "http://127.0.0.1:18186/stuck?d=10s": EOF
new active idle new active closed closed

"""#

private let timeoutHandlerSource = #"""
package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

func main() {
	port := "18285"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	addr := "127.0.0.1:" + port
	base := "http://" + addr
	writes := make(chan string, 4)
	slow := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		d, _ := time.ParseDuration(r.URL.Query().Get("d"))
		w.Header().Set("X-Slow", "yes")
		select {
		case <-time.After(d):
		case <-r.Context().Done():
		}
		w.WriteHeader(http.StatusAccepted)
		_, err := fmt.Fprintln(w, "slow", d)
		writes <- fmt.Sprint(r.Context().Err(), " ", err)
	})
	mux := http.NewServeMux()
	mux.Handle("/msg", http.TimeoutHandler(slow, 200*time.Millisecond, "too slow\n"))
	mux.Handle("/page", http.TimeoutHandler(slow, 200*time.Millisecond, ""))
	ln, _ := net.Listen("tcp", addr)
	go http.Serve(ln, mux)

	for _, path := range []string{"/msg?d=100ms", "/msg?d=1s", "/page?d=1s"} {
		start := time.Now()
		resp, err := http.Get(base + path)
		if err != nil {
			fmt.Println(err)
			continue
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		fmt.Printf("%s %d %q %q %q %v\n", path, resp.StatusCode, b, resp.Header.Get("X-Slow"), resp.Header.Get("Content-Type"), time.Since(start).Round(100*time.Millisecond))
		fmt.Println(<-writes)
	}
	fmt.Println(http.ErrHandlerTimeout)
}

"""#

private let timeoutHandlerExpected = #"""
/msg?d=100ms 202 "slow 100ms\n" "yes" "text/plain; charset=utf-8" 100ms
<nil> <nil>
/msg?d=1s 503 "too slow\n" "" "text/plain; charset=utf-8" 200ms
context deadline exceeded http: Handler timeout
/page?d=1s 503 "<html><head><title>Timeout</title></head><body><h1>Timeout</h1></body></html>" "" "text/html; charset=utf-8" 200ms
context deadline exceeded http: Handler timeout
http: Handler timeout

"""#

private let netCloseSource = #"""
package main

import (
	"fmt"
	"net"
	"os"
	"strings"
	"time"
)

func main() {
	port := "18284"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	addr := "127.0.0.1:" + port
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Println(err)
		return
	}
	// Close wakes an Accept that waits, and fails one that comes after.
	accepted := make(chan error)
	go func() {
		_, err := ln.Accept()
		accepted <- err
	}()
	time.Sleep(10 * time.Millisecond)
	ln.Close()
	fmt.Println(<-accepted)
	_, err = ln.Accept()
	fmt.Println(err)

	// Close wakes a Read that waits, on either side, and fails one that
	// comes after; the peer sees the end of the connection.
	ln, _ = net.Listen("tcp", addr)
	conns := make(chan net.Conn)
	go func() {
		c, _ := ln.Accept()
		conns <- c
	}()
	client, err := net.Dial("tcp", addr)
	if err != nil {
		fmt.Println(err)
		return
	}
	server := <-conns
	read := make(chan string)
	go func() {
		buf := make([]byte, 16)
		n, err := server.Read(buf)
		read <- fmt.Sprint(n, " ", strings.HasSuffix(err.Error(), ": use of closed network connection"))
	}()
	time.Sleep(10 * time.Millisecond)
	server.Close()
	fmt.Println(<-read)
	buf := make([]byte, 16)
	n, err := server.Read(buf)
	fmt.Println(n, strings.HasSuffix(err.Error(), ": use of closed network connection"))
	n, err = client.Read(buf)
	fmt.Println(n, err)
	client.Close()
	ln.Close()
	// A listener on the same address again: the port is free.
	ln, err = net.Listen("tcp", addr)
	fmt.Println(err)
	ln.Close()
}

"""#

private let netCloseExpected = #"""
accept tcp 127.0.0.1:18284: use of closed network connection
accept tcp 127.0.0.1:18284: use of closed network connection
0 true
0 true
0 EOF
<nil>

"""#
