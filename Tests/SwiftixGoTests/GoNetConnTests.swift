/// `net` as Go has it, apart from the network: `net.Conn`, `net.Listener`,
/// `net.Addr`, and `net.Error` are Go's interfaces, so a type of the program
/// is one and a struct that embeds one has its methods; `*net.TCPAddr`,
/// `net.IP`, `*net.OpError`, `*net.AddrError`, `SplitHostPort`, and
/// `JoinHostPort` are Go's. The package is Go text of the library
/// (`Sources/SwiftixGoLibrary/net`); `GoNetServerTests` runs it over a
/// network.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// is the first one its compiler reports, copied without change.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go net connections as interfaces")
struct GoNetConnTests: GoTestHarness {

    /// The first error of compiling `body` as the body of `func main`, as
    /// `line:column: message`: what Go prints after the name of the file.
    private func firstError(
        _ body: String, imports: [String] = ["fmt"], declarations: String = ""
    ) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [
                GoSourceFile(
                    path: "main.go",
                    text: goMainSource(body, imports: imports, declarations: declarations))
            ])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return String(diagnostic.description.dropFirst("main.go:".count))
        } catch {
            return String(describing: error)
        }
    }

    /// A type of the program with the eight methods is a `net.Conn`; a struct
    /// that embeds one has them, overrides some, and is one too; assertions and
    /// type switches see that.
    @Test func aProgramTypeIsAConnection() throws {
        #expect(
            try runGoMain(
                #"""
                p := &pipe{}
                var c net.Conn = p
                fmt.Println(use(c))
                w := &counted{Conn: p}
                c = w
                fmt.Println(use(c), w.written, c.LocalAddr(), c.RemoteAddr().Network())
                fmt.Println(c.SetWriteDeadline(time.Time{}), c.SetDeadline(time.Now()))
                var x any = c
                if conn, ok := x.(net.Conn); ok {
                    fmt.Printf("%T %v\n", conn, conn.RemoteAddr())
                }
                switch v := x.(type) {
                case io.ReadWriteCloser:
                    fmt.Printf("closer %T\n", v)
                }
                _, ok := x.(interface{ LocalAddr() net.Addr })
                fmt.Println(ok)
                fmt.Println(c.Close(), p.closed)
                _, err := c.Read(make([]byte, 1))
                fmt.Println(err, errors.Is(err, net.ErrClosed))
                var none net.Conn
                fmt.Println(none == nil, none)
                """#,
                imports: ["errors", "fmt", "io", "net", "time"],
                declarations: """
                    type addr string

                    func (a addr) Network() string { return "pipe" }
                    func (a addr) String() string  { return string(a) }

                    // pipe is a net.Conn of the program: a test double.
                    type pipe struct {
                        data   []byte
                        closed bool
                    }

                    func (p *pipe) Read(b []byte) (int, error) {
                        if p.closed {
                            return 0, &net.OpError{Op: "read", Net: "pipe", Err: net.ErrClosed}
                        }
                        k := copy(b, p.data)
                        p.data = p.data[k:]
                        return k, nil
                    }
                    func (p *pipe) Write(b []byte) (int, error)        { p.data = append(p.data, b...); return len(b), nil }
                    func (p *pipe) Close() error                       { p.closed = true; return nil }
                    func (p *pipe) LocalAddr() net.Addr                { return addr("local") }
                    func (p *pipe) RemoteAddr() net.Addr               { return addr("remote") }
                    func (p *pipe) SetDeadline(t time.Time) error      { return nil }
                    func (p *pipe) SetReadDeadline(t time.Time) error  { return nil }
                    func (p *pipe) SetWriteDeadline(t time.Time) error { return errors.New("no write deadline") }

                    type counted struct {
                        net.Conn
                        written int
                    }

                    func (c *counted) Write(b []byte) (int, error) {
                        n, err := c.Conn.Write(b)
                        c.written += n
                        return n, err
                    }

                    var _ net.Conn = (*pipe)(nil)

                    func use(c net.Conn) string {
                        c.Write([]byte("ping"))
                        b := make([]byte, 8)
                        k, _ := c.Read(b)
                        return string(b[:k])
                    }
                    """)
                == """
                ping
                ping 4 local pipe
                no write deadline <nil>
                *main.counted remote
                closer *main.counted
                true
                <nil> true
                read pipe: use of closed network connection true
                true <nil>

                """)
        #expect(
            try runGoMain(
                """
                type local struct{ Conn }
                counter := 0
                send := func(c net.Conn) {
                    c.Write([]byte("x"))
                    counter++
                }
                p := &pipe{}
                var c Conn = local{p}
                send(c)
                send(p)
                fmt.Println(counter, len(p.data), c.LocalAddr())
                var l net.Listener = &listener{conns: []net.Conn{c}}
                got, err := l.Accept()
                fmt.Println(got == c, err, l.Addr())
                _, err = l.Accept()
                fmt.Println(err, l.Close())
                """,
                imports: ["errors", "fmt", "net", "time"],
                declarations: """
                    type addr string

                    func (a addr) Network() string { return "pipe" }
                    func (a addr) String() string  { return string(a) }

                    // pipe is a net.Conn of the program: a test double.
                    type pipe struct {
                        data   []byte
                        closed bool
                    }

                    func (p *pipe) Read(b []byte) (int, error) {
                        if p.closed {
                            return 0, &net.OpError{Op: "read", Net: "pipe", Err: net.ErrClosed}
                        }
                        k := copy(b, p.data)
                        p.data = p.data[k:]
                        return k, nil
                    }
                    func (p *pipe) Write(b []byte) (int, error)        { p.data = append(p.data, b...); return len(b), nil }
                    func (p *pipe) Close() error                       { p.closed = true; return nil }
                    func (p *pipe) LocalAddr() net.Addr                { return addr("local") }
                    func (p *pipe) RemoteAddr() net.Addr               { return addr("remote") }
                    func (p *pipe) SetDeadline(t time.Time) error      { return nil }
                    func (p *pipe) SetReadDeadline(t time.Time) error  { return nil }
                    func (p *pipe) SetWriteDeadline(t time.Time) error { return errors.New("no write deadline") }

                    type Conn = net.Conn

                    // listener hands out the connections it was given, then fails.
                    type listener struct {
                        conns []net.Conn
                    }

                    func (l *listener) Accept() (net.Conn, error) {
                        if len(l.conns) == 0 {
                            return nil, &net.OpError{Op: "accept", Net: "pipe", Addr: l.Addr(), Err: net.ErrClosed}
                        }
                        c := l.conns[0]
                        l.conns = l.conns[1:]
                        return c, nil
                    }
                    func (l *listener) Close() error   { return nil }
                    func (l *listener) Addr() net.Addr { return addr("listener") }
                    """)
                == """
                2 2 local
                true <nil> listener
                accept pipe listener: use of closed network connection <nil>

                """)
    }

    /// `SplitHostPort`, `JoinHostPort`, `net.IP`, and `*net.TCPAddr`, with Go's
    /// errors and text.
    @Test func addressesAreGos() throws {
        #expect(
            try runGoMain(
                #"""
                for _, s := range []string{"a:1", "[::1]:2", "a", "a:b:c", "[a]b:1", "[a:1", "]a:1", ":", "[]:", "h:"} {
                    h, p, err := net.SplitHostPort(s)
                    fmt.Printf("%q %q %v %T\n", h, p, err, err)
                }
                fmt.Println(net.JoinHostPort("::1", "80"), net.JoinHostPort("h", "80"), net.JoinHostPort("", "0"))
                for _, s := range []string{"127.0.0.1", "::1", "::", "2001:db8::68", "fe80::1:2:0:0:3", "1:0:0:2:0:0:0:3", "::ffff:1.2.3.4", "x", "1.2.3", "256.1.1.1", "01.2.3.4", ":::"} {
                    ip := net.ParseIP(s)
                    fmt.Println(s, ip, len(ip), ip == nil, ip.To4() != nil)
                }
                fmt.Println(net.IPv4(10, 0, 0, 1), net.IPv4(127, 0, 0, 1).IsLoopback(), net.IPv6unspecified.IsUnspecified())
                fmt.Println(net.IPv4(1, 2, 3, 4).Equal(net.IP{1, 2, 3, 4}), net.IP{1, 2, 3}, net.IP(nil))
                var ip net.IP
                fmt.Println(ip, (&net.TCPAddr{}).String(), &net.TCPAddr{IP: net.IPv4(1, 2, 3, 4), Port: 5})
                fmt.Println(&net.TCPAddr{IP: net.ParseIP("::1"), Port: 8080, Zone: "lo0"}, (*net.TCPAddr)(nil))
                var a net.Addr = &net.TCPAddr{IP: net.ParseIP("10.1.2.3"), Port: 80}
                fmt.Printf("%v %s %T %v\n", a, a.Network(), a, a.(*net.TCPAddr).Port)
                """#,
                imports: ["fmt", "net"])
                == """
                "a" "1" <nil> <nil>
                "::1" "2" <nil> <nil>
                "" "" address a: missing port in address *net.AddrError
                "" "" address a:b:c: too many colons in address *net.AddrError
                "" "" address [a]b:1: missing port in address *net.AddrError
                "" "" address [a:1: missing ']' in address *net.AddrError
                "" "" address ]a:1: unexpected ']' in address *net.AddrError
                "" "" <nil> <nil>
                "" "" <nil> <nil>
                "h" "" <nil> <nil>
                [::1]:80 h:80 :0
                127.0.0.1 127.0.0.1 16 false true
                ::1 ::1 16 false false
                :: :: 16 false false
                2001:db8::68 2001:db8::68 16 false false
                fe80::1:2:0:0:3 fe80::1:2:0:0:3 16 false false
                1:0:0:2:0:0:0:3 1:0:0:2::3 16 false false
                ::ffff:1.2.3.4 1.2.3.4 16 false true
                x <nil> 0 true false
                1.2.3 <nil> 0 true false
                256.1.1.1 <nil> 0 true false
                01.2.3.4 <nil> 0 true false
                ::: <nil> 0 true false
                10.0.0.1 true true
                true ?010203 <nil>
                <nil> :0 1.2.3.4:5
                [::1%lo0]:8080 <nil>
                10.1.2.3:80 tcp *net.TCPAddr 80

                """)
    }

    /// `*net.OpError` and the errors it wraps print, unwrap, and report timeouts
    /// as Go's; an address `Dial` and `Listen` cannot use is refused before any
    /// connection, with Go's error.
    @Test func errorsAreGos() throws {
        #expect(
            try runGoMain(
                #"""
                var err error = &net.OpError{Op: "read", Net: "tcp", Source: &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}, Addr: &net.TCPAddr{IP: net.ParseIP("::1"), Port: 80}, Err: os.ErrDeadlineExceeded}
                fmt.Println(err)
                var ne net.Error
                fmt.Println(errors.As(err, &ne), ne.Timeout(), errors.Is(err, os.ErrDeadlineExceeded), errors.Unwrap(err))
                fmt.Println(os.ErrDeadlineExceeded, net.ErrClosed)
                err = &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("boom")}
                fmt.Println(err, err.(*net.OpError).Timeout(), err.(*net.OpError).Temporary())
                fmt.Println(&net.AddrError{Err: "bad", Addr: "x"}, &net.AddrError{Err: "bad"}, net.UnknownNetworkError("foo"))
                fmt.Println(&net.DNSError{Err: "no such host", Name: "example.invalid", Server: "10.0.0.1:53"})
                fmt.Println(os.NewSyscallError("connect", errors.New("refused")), os.NewSyscallError("x", nil) == nil)
                for _, a := range []string{"nonsense", "x:y", "127.0.0.1:99999", "[::1", "a:b:c", "127.0.0.1:-1"} {
                    _, err := net.Dial("tcp", a)
                    fmt.Printf("%v | %T\n", err, err)
                    oe := err.(*net.OpError)
                    fmt.Printf("  %q %q %v %v %T\n", oe.Op, oe.Net, oe.Source, oe.Addr, oe.Err)
                    _, err = net.Listen("tcp", a)
                    fmt.Println(" ", err)
                }
                _, err = net.Dial("udp4x", "1.2.3.4:5")
                fmt.Printf("%v %T\n", err, err)
                _, err = net.Listen("bogus", ":80")
                fmt.Println(err)
                """#,
                imports: ["errors", "fmt", "net", "os"])
                == """
                read tcp 127.0.0.1:1->[::1]:80: i/o timeout
                true true true i/o timeout
                i/o timeout use of closed network connection
                dial tcp: boom false false
                address x: bad bad unknown network foo
                lookup example.invalid on 10.0.0.1:53: no such host
                connect: refused true
                dial tcp: address nonsense: missing port in address | *net.OpError
                  "dial" "tcp" <nil> <nil> *net.AddrError
                  listen tcp: address nonsense: missing port in address
                dial tcp: lookup tcp/y: unknown port | *net.OpError
                  "dial" "tcp" <nil> <nil> *net.DNSError
                  listen tcp: lookup tcp/y: unknown port
                dial tcp: address 99999: invalid port | *net.OpError
                  "dial" "tcp" <nil> <nil> *net.AddrError
                  listen tcp: address 99999: invalid port
                dial tcp: address [::1: missing ']' in address | *net.OpError
                  "dial" "tcp" <nil> <nil> *net.AddrError
                  listen tcp: address [::1: missing ']' in address
                dial tcp: address a:b:c: too many colons in address | *net.OpError
                  "dial" "tcp" <nil> <nil> *net.AddrError
                  listen tcp: address a:b:c: too many colons in address
                dial tcp: address -1: invalid port | *net.OpError
                  "dial" "tcp" <nil> <nil> *net.AddrError
                  listen tcp: address -1: invalid port
                dial udp4x: unknown network udp4x *net.OpError
                listen bogus: unknown network bogus

                """)
    }

    /// A type that lacks a method of `net.Conn` is no connection, with Go's
    /// first error.
    @Test func mistakesAreRefusedAsGoRefusesThem() {
        #expect(
            firstError(
                """
                var c net.Conn = half{}
                fmt.Println(c)
                """,
                imports: ["fmt", "net"],
                declarations: """
                    type half struct{}

                    func (half) Read(b []byte) (int, error)  { return 0, nil }
                    func (half) Write(b []byte) (int, error) { return 0, nil }
                    func (half) Close() error                { return nil }
                    """)
                == "10:18: cannot use half{} (value of struct type half) as net.Conn value in variable declaration: half does not implement net.Conn (missing method LocalAddr)")
        #expect(
            firstError(
                """
                var l net.Listener = &lst{}
                fmt.Println(l)
                """,
                imports: ["fmt", "net"],
                declarations: """
                    type lst struct{}

                    func (*lst) Accept() (net.Conn, error) { return nil, nil }
                    func (*lst) Close() error              { return nil }
                    func (*lst) Addr() string              { return "" }
                    """)
                == "10:22: cannot use &lst{} (value of type *lst) as net.Listener value in variable declaration: *lst does not implement net.Listener (wrong type for method Addr)\n\t\thave Addr() string\n\t\twant Addr() net.Addr")
        #expect(
            firstError(
                """
                var c net.Conn
                c.Foo()
                fmt.Println(c)
                """,
                imports: ["fmt", "net"])
                == "7:3: c.Foo undefined (type net.Conn has no field or method Foo)")
        #expect(
            firstError(
                """
                var e net.Error = errors.New("x")
                fmt.Println(e)
                """,
                imports: ["errors", "fmt", "net"])
                == "7:19: cannot use errors.New(\"x\") (value of interface type error) as net.Error value in variable declaration: error does not implement net.Error (missing method Temporary)")
        #expect(
            firstError(
                """
                c, err := net.Dial("tcp")
                fmt.Println(c, err)
                """,
                imports: ["fmt", "net"])
                == "6:20: not enough arguments in call to net.Dial\n\thave (string)\n\twant (string, string)")
        #expect(
            firstError(
                """
                var a net.Addr = net.TCPAddr{}
                fmt.Println(a)
                """,
                imports: ["fmt", "net"])
                == "6:18: cannot use net.TCPAddr{} (value of struct type net.TCPAddr) as net.Addr value in variable declaration: net.TCPAddr does not implement net.Addr (method Network has pointer receiver)")
    }
}
