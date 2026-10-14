/// `net` over a network: an echo server whose connections time out when
/// idle, a client that goes quiet, wrappers of `net.Conn` and
/// `net.Listener` that count bytes, deadlines that wake a waiting `Read` and
/// leave the connection usable, `Close` from another goroutine, and the
/// addresses and errors of `Listen`, `Accept`, and `Dial`.
///
/// Each program runs as a process of a kernel with a loopback interface and
/// prints what it sees; the expected text is what the same program printed
/// under Go 1.24.5. Durations are of the logical clock, which the run
/// advances while every goroutine waits, so a timeout costs no wall time.
///
/// Concurrency: every test builds its own `EventLoop` + `Kernel` and drives
/// it on the calling executor; nothing is shared between tests.

import Testing

@testable import Swiftix
@testable import SwiftixGo
@testable import SwiftixGoRuntime

@Suite("Go net servers, deadlines, and errors")
struct GoNetServerTests {

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

    /// An echo server that closes a connection idle for 200 ms, through a
    /// listener and connections of the program that count bytes; a client
    /// that talks and then goes quiet, one whose own deadline passes and
    /// which then reads on, and a write past a write deadline. The errors
    /// are `*net.OpError` with Go's fields, `Timeout`, and sentinels.
    @Test func anEchoServerClosesIdleConnections() throws {
        try expectGo(idleEchoSource, idleEchoExpected)
    }

    /// The addresses of listeners on every interface, the loopback one, and
    /// `localhost`, and the errors of a second listener, a foreign address,
    /// a refused dial, and a closed listener; a deadline that another
    /// goroutine sets or that passed, bytes that arrive after a timeout,
    /// and `Close` from another goroutine. The package is imported under
    /// another name.
    @Test func listenersDeadlinesAndClosesAreGos() throws {
        try expectGo(deadlinesSource, deadlinesExpected)
    }
}

private let idleEchoSource = #"""
package main

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"time"
)

const idle = 200 * time.Millisecond

// countingConn is a net.Conn that counts the bytes through it.
type countingConn struct {
	net.Conn
	mu      sync.Mutex
	read    int
	written int
}

func (c *countingConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.mu.Lock()
	c.read += n
	c.mu.Unlock()
	return n, err
}

func (c *countingConn) Write(b []byte) (int, error) {
	n, err := c.Conn.Write(b)
	c.mu.Lock()
	c.written += n
	c.mu.Unlock()
	return n, err
}

// countingListener wraps every connection it accepts.
type countingListener struct {
	net.Listener
	mu    sync.Mutex
	conns []*countingConn
}

func (l *countingListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	cc := &countingConn{Conn: c}
	l.mu.Lock()
	l.conns = append(l.conns, cc)
	l.mu.Unlock()
	return cc, nil
}

func describe(err error) string {
	if err == nil {
		return "<nil>"
	}
	if err == io.EOF {
		return "EOF"
	}
	var oe *net.OpError
	if !errors.As(err, &oe) {
		return fmt.Sprintf("%T %v", err, err)
	}
	var ne net.Error
	timeout := errors.As(err, &ne) && ne.Timeout()
	src := "<nil>"
	if a, ok := oe.Source.(*net.TCPAddr); ok {
		src = a.IP.String()
	}
	return fmt.Sprintf("%T op=%s net=%s src=%v err=%v timeout=%v deadline=%v closed=%v",
		err, oe.Op, oe.Net, src, oe.Err, timeout,
		errors.Is(err, os.ErrDeadlineExceeded), errors.Is(err, net.ErrClosed))
}

func serve(c net.Conn, report chan<- string) {
	buf := make([]byte, 64)
	for {
		c.SetReadDeadline(time.Now().Add(idle))
		n, err := c.Read(buf)
		if err != nil {
			c.Close()
			msg := err.Error()
			report <- fmt.Sprintf("server: %s (%v %v)", describe(err),
				strings.HasPrefix(msg, "read tcp 127.0.0.1:18301->127.0.0.1:"),
				strings.HasSuffix(msg, ": i/o timeout"))
			return
		}
		c.Write([]byte(strings.ToUpper(string(buf[:n]))))
	}
}

func main() {
	inner, err := net.Listen("tcp", "127.0.0.1:18301")
	if err != nil {
		fmt.Println(err)
		return
	}
	ln := &countingListener{Listener: inner}
	var l net.Listener = ln
	fmt.Printf("%T %v %s\n", l.Addr(), l.Addr(), l.Addr().Network())
	report := make(chan string)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				report <- "accept: " + describe(err)
				return
			}
			go serve(c, report)
		}
	}()

	// A client that talks, then goes quiet: the server closes it.
	c, err := net.Dial("tcp", "127.0.0.1:18301")
	if err != nil {
		fmt.Println(err)
		return
	}
	fmt.Printf("%T %v %T\n", c, c.RemoteAddr(), c.LocalAddr())
	buf := make([]byte, 64)
	for _, word := range []string{"hello", "world"} {
		c.Write([]byte(word))
		n, err := c.Read(buf)
		fmt.Println(string(buf[:n]), err)
		time.Sleep(100 * time.Millisecond) // shorter than the idle timeout
	}
	start := time.Now()
	n, err := c.Read(buf)
	waited := time.Since(start)
	fmt.Println(n, describe(err), waited >= 100*time.Millisecond, waited < 300*time.Millisecond)
	fmt.Println(<-report)
	c.Close()

	// A client with a deadline of its own, which it then clears: the
	// connection stays usable, and sees the server's close.
	c, _ = net.Dial("tcp", "127.0.0.1:18301")
	c.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
	n, err = c.Read(buf)
	fmt.Println(n, describe(err))
	c.SetReadDeadline(time.Time{})
	c.Write([]byte("again"))
	n, err = c.Read(buf)
	fmt.Println(string(buf[:n]), err)
	n, err = c.Read(buf)
	fmt.Println(n, describe(err))
	fmt.Println(<-report)
	// A write after a write deadline that passed.
	c.SetWriteDeadline(time.Now().Add(-time.Second))
	n, err = c.Write([]byte("late"))
	fmt.Println(n, describe(err))
	c.Close()
	n, err = c.Read(buf)
	fmt.Println(n, describe(err))
	fmt.Println(c.Close() != nil, c.SetDeadline(time.Now()) != nil)

	l.Close()
	fmt.Println(<-report)
	ln.mu.Lock()
	for i, cc := range ln.conns {
		cc.mu.Lock()
		fmt.Println("conn", i, "read", cc.read, "written", cc.written)
		cc.mu.Unlock()
	}
	ln.mu.Unlock()
}
"""#

private let idleEchoExpected = #"""
*net.TCPAddr 127.0.0.1:18301 tcp
*net.TCPConn 127.0.0.1:18301 *net.TCPAddr
HELLO <nil>
WORLD <nil>
0 EOF true true
server: *net.OpError op=read net=tcp src=127.0.0.1 err=i/o timeout timeout=true deadline=true closed=false (true true)
0 *net.OpError op=read net=tcp src=127.0.0.1 err=i/o timeout timeout=true deadline=true closed=false
AGAIN <nil>
0 EOF
server: *net.OpError op=read net=tcp src=127.0.0.1 err=i/o timeout timeout=true deadline=true closed=false (true true)
0 *net.OpError op=write net=tcp src=127.0.0.1 err=i/o timeout timeout=true deadline=true closed=false
0 *net.OpError op=read net=tcp src=127.0.0.1 err=use of closed network connection timeout=false deadline=false closed=true
true true
accept: *net.OpError op=accept net=tcp src=<nil> err=use of closed network connection timeout=false deadline=false closed=true
conn 0 read 10 written 10
conn 1 read 5 written 5

"""#

private let deadlinesSource = #"""
package main

import (
	"errors"
	"fmt"
	n "net"
	"time"
)

type addrer interface{ LocalAddr() n.Addr }

func main() {
	for _, a := range []string{":18310", "127.0.0.1:18311", "localhost:18312", "0.0.0.0:18313", "1.2.3.4:18314"} {
		ln, err := n.Listen("tcp", a)
		fmt.Printf("listen %q: %v\n", a, err)
		if err != nil {
			continue
		}
		ad := ln.Addr().(*n.TCPAddr)
		fmt.Printf("  %v %T %s %q %d\n", ad, ad, ad.Network(), ad.IP, len(ad.IP))
		_, err = n.Listen("tcp", a)
		fmt.Println("  again:", err)
		fmt.Println("  close:", ln.Close())
		fmt.Println("  close again:", ln.Close())
		_, err = ln.Accept()
		fmt.Println("  accept:", err)
	}
	_, err := n.Dial("tcp", "127.0.0.1:18315")
	fmt.Printf("%v %T %T\n", err, err, errors.Unwrap(err))

	ln, err := n.Listen("tcp", "127.0.0.1:18316")
	if err != nil {
		fmt.Println(err)
		return
	}
	got := make(chan n.Conn)
	go func() {
		s, _ := ln.Accept()
		got <- s
	}()
	d, _ := n.Dial("tcp", "127.0.0.1:18316")
	s := <-got
	fmt.Printf("%T %v %v\n", s, s.LocalAddr(), s.RemoteAddr().(*n.TCPAddr).IP)
	fmt.Println(d.RemoteAddr(), d.LocalAddr().(*n.TCPAddr).IP, d.LocalAddr().(*n.TCPAddr).Port == s.RemoteAddr().(*n.TCPAddr).Port)
	var y any = s
	_, ok := y.(addrer)
	fmt.Println(ok)
	_, ok = y.(interface{ SetDeadline(time.Time) error })
	fmt.Println(ok)
	tcp := d.(*n.TCPConn)
	fmt.Println(tcp.RemoteAddr().(*n.TCPAddr).Port, tcp.RemoteAddr().(*n.TCPAddr).IP.IsLoopback())

	// A deadline set from another goroutine wakes a Read that waits, and
	// a deadline that passed fails a Read at once.
	go func() {
		time.Sleep(30 * time.Millisecond)
		s.SetReadDeadline(time.Now())
	}()
	buf := make([]byte, 4)
	k, err := s.Read(buf)
	var ne n.Error
	fmt.Println(k, errors.As(err, &ne) && ne.Timeout())
	k, err = s.Read(buf)
	fmt.Println(k, errors.Is(err, os_deadline(err)))
	// What arrives after a timeout is read after a new deadline.
	d.Write([]byte("late"))
	time.Sleep(10 * time.Millisecond)
	s.SetDeadline(time.Now().Add(time.Hour))
	k, err = s.Read(buf[:2])
	fmt.Println(string(buf[:k]), err)
	k, err = s.Read(buf)
	fmt.Println(string(buf[:k]), err)
	// A Close from another goroutine wakes a Read that waits.
	go func() {
		time.Sleep(30 * time.Millisecond)
		s.Close()
	}()
	k, err = s.Read(buf)
	fmt.Println(k, errors.Is(err, n.ErrClosed))
	fmt.Println(s.SetReadDeadline(time.Time{}) != nil)
	k, err = d.Read(buf)
	fmt.Println(k, err)
	d.Close()
	ln.Close()
}

func os_deadline(err error) error {
	var oe *n.OpError
	if errors.As(err, &oe) {
		return oe.Err
	}
	return nil
}
"""#

private let deadlinesExpected = #"""
listen ":18310": <nil>
  [::]:18310 *net.TCPAddr tcp "::" 16
  again: listen tcp :18310: bind: address already in use
  close: <nil>
  close again: close tcp [::]:18310: use of closed network connection
  accept: accept tcp [::]:18310: use of closed network connection
listen "127.0.0.1:18311": <nil>
  127.0.0.1:18311 *net.TCPAddr tcp "127.0.0.1" 4
  again: listen tcp 127.0.0.1:18311: bind: address already in use
  close: <nil>
  close again: close tcp 127.0.0.1:18311: use of closed network connection
  accept: accept tcp 127.0.0.1:18311: use of closed network connection
listen "localhost:18312": <nil>
  127.0.0.1:18312 *net.TCPAddr tcp "127.0.0.1" 4
  again: listen tcp 127.0.0.1:18312: bind: address already in use
  close: <nil>
  close again: close tcp 127.0.0.1:18312: use of closed network connection
  accept: accept tcp 127.0.0.1:18312: use of closed network connection
listen "0.0.0.0:18313": <nil>
  [::]:18313 *net.TCPAddr tcp "::" 16
  again: listen tcp 0.0.0.0:18313: bind: address already in use
  close: <nil>
  close again: close tcp [::]:18313: use of closed network connection
  accept: accept tcp [::]:18313: use of closed network connection
listen "1.2.3.4:18314": listen tcp 1.2.3.4:18314: bind: can't assign requested address
dial tcp 127.0.0.1:18315: connect: connection refused *net.OpError *os.SyscallError
*net.TCPConn 127.0.0.1:18316 127.0.0.1
127.0.0.1:18316 127.0.0.1 true
true
true
18316 true
0 true
0 true
la <nil>
te <nil>
0 true
true
0 EOF

"""#
