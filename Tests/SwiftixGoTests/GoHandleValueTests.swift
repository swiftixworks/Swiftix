/// The handle types of the library, `net.Conn`, `net.Listener`, and
/// `*os.File`, as the values Go says they are.
///
/// A `net.Conn` and a `net.Listener` are interfaces: `nil` is their zero
/// value, they are compared with `nil`, asserted, and switched on, they are
/// values of every interface that asks for no more than their methods
/// (`io.ReadWriteCloser`, one of the program's own), and a struct that
/// embeds one has its methods. A `*os.File` is a value of the interfaces its
/// methods satisfy. A call the compiler sees stays the instruction it was;
/// one through an interface finds the method among the functions the VM
/// provides (`GoLibraryMethods.handleFunctions`).
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// is the first one its compiler reports, copied without change.

@testable import SwiftixGo
import Testing

@testable import Swiftix
@testable import SwiftixGoRuntime
@testable import SwiftixGoTool

@Suite("Go library handles as values")
struct GoHandleValueTests: GoTestHarness {

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

    /// Compiles `text`, one whole file, and returns what the program prints.
    private func runGoProgram(_ text: String) throws -> String {
        let executable = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: text)])
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    /// The message of the diagnostic that compiling `text` produces, or nil.
    private func goProgramDiagnostic(_ text: String) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [GoSourceFile(path: "main.go", text: text)])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return diagnostic.message
        } catch {
            return "unexpected error: \(error)"
        }
    }

    /// A handle is the result of a function, a field left unset, an element,
    /// and a variable without a value. A nil connection or listener panics where
    /// it is used, also through an interface and through a struct that embeds it;
    /// a nil file gives Go's error. A file is a value of `io.Writer`, of
    /// `io.Closer`, and of an interface of the program, by assignment, assertion,
    /// and through a struct that embeds it.
    @Test func aHandleHasNilForItsZeroValueAndPanicsOnUseAsGoDoes() throws {
        #expect(
            try runGoProgram(
                #"""
                package main

                import (
                    "fmt"
                    "io"
                    "net"
                    "os"
                )

                type server struct {
                    net.Listener
                    conns chan net.Conn
                    last  net.Conn
                    out   *os.File
                }

                type logger struct {
                    *os.File
                    prefix string
                }

                type reader interface {
                    Read(p []byte) (n int, err error)
                }

                func try(name string, f func()) {
                    defer func() {
                        if r := recover(); r != nil {
                            fmt.Println(name, "panic:", r)
                        }
                    }()
                    f()
                }

                func open(ok bool) (net.Listener, net.Conn, *os.File) {
                    if !ok {
                        return nil, nil, nil
                    }
                    return nil, nil, os.Stdout
                }

                func main() {
                    var conn net.Conn
                    var listener net.Listener
                    var file *os.File
                    buf := make([]byte, 4)
                    try("conn.Read", func() { conn.Read(buf) })
                    try("conn.Write", func() { conn.Write(buf) })
                    try("conn.Close", func() { conn.Close() })
                    try("listener.Accept", func() { listener.Accept() })
                    try("listener.Close", func() { listener.Close() })
                    try("file.Write", func() {
                        n, err := file.Write(buf)
                        fmt.Println(n, err)
                    })
                    try("file.Close", func() { fmt.Println(file.Close()) })
                    try("reader", func() {
                        var r io.Reader = conn
                        fmt.Println(r == nil)
                        r.Read(buf)
                    })
                    try("closer", func() {
                        var c io.Closer = listener
                        fmt.Println(c == nil)
                        c.Close()
                    })
                    try("file closer", func() {
                        var c io.Closer = file
                        fmt.Println(c == nil, c.Close())
                    })
                    try("assert", func() {
                        var a any = conn
                        fmt.Println(a == nil, a.(net.Conn))
                    })
                    try("assert int", func() {
                        var a any = 5
                        fmt.Println(a.(net.Conn))
                    })
                    try("assert file", func() {
                        var a any = os.Stdout
                        fmt.Println(a.(net.Listener))
                    })
                    try("assert own", func() {
                        var a any = os.Stdout
                        r := a.(reader)
                        _, isWriter := a.(io.Writer)
                        _, isConn := a.(net.Conn)
                        _, isString := a.(interface{ String() string })
                        fmt.Println(r != nil, isWriter, isConn, isString)
                    })

                    s := server{conns: make(chan net.Conn, 1)}
                    l, c, f := open(false)
                    fmt.Println(s.Listener == nil, s.last == nil, s.out == nil, l == nil, c == nil, f == nil, len(s.conns))
                    s.conns <- nil
                    got := <-s.conns
                    fmt.Println(got == nil, got == conn, s.last == got)
                    conns := []net.Conn{nil, conn}
                    byName := map[string]net.Listener{"none": nil}
                    held, found := byName["none"]
                    fmt.Println(len(conns), conns[0] == nil, held == nil, found, byName["x"] == nil)
                    try("embedded", func() { s.Accept() })
                    _, _, f = open(true)
                    log := logger{File: f, prefix: "log: "}
                    log.WriteString(log.prefix + "promoted\n")
                    var w io.Writer = log
                    fmt.Fprintln(w, "through a writer")
                    n, err := io.WriteString(log, "io.WriteString\n")
                    fmt.Println(n, err, f == os.Stdout, log.File == os.Stdout)
                    fmt.Printf("%T %T %T %v %v\n", conn, listener, file, conn, listener)
                    var e error
                    fmt.Printf("%v %v\n", e, []net.Conn{nil})
                }
                """#)
                == """
                conn.Read panic: runtime error: invalid memory address or nil pointer dereference
                conn.Write panic: runtime error: invalid memory address or nil pointer dereference
                conn.Close panic: runtime error: invalid memory address or nil pointer dereference
                listener.Accept panic: runtime error: invalid memory address or nil pointer dereference
                listener.Close panic: runtime error: invalid memory address or nil pointer dereference
                0 invalid argument
                invalid argument
                true
                reader panic: runtime error: invalid memory address or nil pointer dereference
                true
                closer panic: runtime error: invalid memory address or nil pointer dereference
                false invalid argument
                assert panic: interface conversion: interface is nil, not net.Conn
                assert int panic: interface conversion: int is not net.Conn: missing method Close
                assert file panic: interface conversion: *os.File is not net.Listener: missing method Accept
                true true false false
                true true true true true true 0
                true true true
                2 true true true true
                embedded panic: runtime error: invalid memory address or nil pointer dereference
                log: promoted
                through a writer
                io.WriteString
                15 <nil> true true
                <nil> <nil> *os.File <nil> <nil>
                <nil> [<nil>]

                """)
    }

    /// Over a real connection, in a process of the kernel: a `net.Conn` as an
    /// `io.Writer`, an `io.ReadWriteCloser`, and an interface of the program; a
    /// type switch that tells a connection, a listener, a file, and a type of the
    /// program apart; an assertion back to `net.Conn`; equality; a struct that
    /// embeds a connection; and connections in a slice and a map. The program and
    /// what it prints are Go's.
    @Test func connectionsAndListenersAreInterfaceValues() throws {
        let source = #"""
            package main

            import (
                "fmt"
                "io"
                "net"
                "os"
            )

            type session struct {
                net.Conn
                name string
            }

            type pool struct {
                listener net.Listener
                conns    []net.Conn
                byName   map[string]net.Conn
                log      *os.File
            }

            type upper struct{ data []byte }

            func (u *upper) Read(p []byte) (int, error)  { return 0, io.EOF }
            func (u *upper) Write(p []byte) (int, error) { u.data = append(u.data, p...); return len(p), nil }
            func (u *upper) Close() error                { return nil }

            type readWriteCloser interface {
                Read(p []byte) (int, error)
                Write(p []byte) (int, error)
                Close() error
            }

            func dial(address string) (net.Conn, error) {
                if address == "" {
                    return nil, fmt.Errorf("no address")
                }
                return net.Dial("tcp", address)
            }

            func kind(v any) string {
                switch c := v.(type) {
                case nil:
                    return "nil"
                case net.Conn:
                    _ = c
                    return "conn"
                case net.Listener:
                    return "listener"
                case *os.File:
                    return "file"
                case io.Writer:
                    return "writer"
                }
                return "other"
            }

            func send(w io.Writer, text string) (int, error) { return w.Write([]byte(text)) }

            func drain(r io.Reader) string {
                buf := make([]byte, 64)
                n, _ := r.Read(buf)
                return string(buf[:n])
            }

            func shut(c io.Closer) error { return c.Close() }

            func main() {
                var conn net.Conn
                var listener net.Listener
                var file *os.File
                p := pool{byName: map[string]net.Conn{}}
                fmt.Println(conn == nil, listener == nil, file == nil, p.listener == nil, p.byName["x"] == nil, len(p.conns), p.log == nil)
                c, err := dial("")
                fmt.Println(c == nil, err, kind(c), kind(conn), kind(os.Stdout), kind(&upper{}), kind(5))

                listener, err = net.Listen("tcp", "127.0.0.1:18431")
                if err != nil {
                    fmt.Println("listen:", err)
                    return
                }
                done := make(chan string)
                go func() {
                    server, err := listener.Accept()
                    if err != nil {
                        done <- "accept: " + err.Error()
                        return
                    }
                    s := session{Conn: server, name: "s"}
                    text := drain(s)
                    send(s.Conn, "echo "+text)
                    s.Write([]byte("!"))
                    done <- "served " + text + " " + kind(server) + " " + kind(s.Conn)
                    shut(s)
                }()
                conn, err = dial("127.0.0.1:18431")
                if err != nil {
                    fmt.Println("dial:", err)
                    return
                }
                p.conns = append(p.conns, conn)
                p.byName["c"] = conn
                var rwc io.ReadWriteCloser = conn
                var own readWriteCloser = conn
                var w io.Writer = conn
                n, err := send(w, "hello")
                fmt.Println(n, err, conn != nil, p.byName["c"] == conn, p.conns[0] == conn, kind(conn), kind(listener), kind(rwc))
                fmt.Println(<-done)
                fmt.Println(drain(rwc) + drain(own))
                back, isConn := rwc.(net.Conn)
                _, isWriter := any(conn).(io.Writer)
                _, isListener := any(conn).(net.Listener)
                fmt.Println(back == conn, isConn, isWriter, isListener)
                fmt.Println(shut(own), shut(listener))

                var out io.Writer = os.Stdout
                send(out, "to stdout\n")
                fmt.Fprintln(out, "fprintln to a writer")
                u := &upper{}
                var asOwn readWriteCloser = u
                send(asOwn, "abc")
                fmt.Println(string(u.data), kind(u))
                f, isFile := out.(*os.File)
                fmt.Println(isFile, f == os.Stdout)
            }
            """#
        // A kernel with a loopback interface, as in `GoKeyValueServerTests`.
        let session = try GoProcessSession(["/handles": source])
        let kernel = session.kernel
        let loop = session.loop
        kernel.netns.stack.configure(
            .addInterface(
                NetworkInterfaceConfiguration(
                    address: IPv4Address(127, 0, 0, 1),
                    mac: MACAddress("00:00:00:00:00:00")!,
                    prefixLength: 8)))
        let loopback = try #require(kernel.netns.stack.interface(at: 0))
        loopback.onEgress = { [weak kernel, weak loopback] frame in
            guard let kernel, let loopback else { return }
            loop.schedule(after: 0) { kernel.netns.stack.receive(frame, on: loopback) }
        }
        let output = session.run("/handles")

        #expect(
            output.split(separator: "\n").joined(separator: "\n") == """
                true true true true true 0 true
                true no address nil nil file writer other
                5 <nil> true true true conn listener conn
                served hello conn conn
                echo hello!
                true true true false
                <nil> <nil>
                to stdout
                fprintln to a writer
                abc writer
                true true
                """)
    }

    /// A type of the program with `Read`, `Write`, and `Close` is no
    /// `net.Conn`: Go's interface has methods it lacks. The errors are Go's.
    @Test func whatIsNoHandleIsRefusedAsGoRefusesIt() {
        #expect(
            firstError(
                """
                var c net.Conn = &mock{}
                fmt.Println(c)
                """,
                imports: ["fmt", "net"],
                declarations: """
                    type mock struct{}

                    func (m *mock) Read(p []byte) (int, error)  { return 0, nil }
                    func (m *mock) Write(p []byte) (int, error) { return 0, nil }
                    func (m *mock) Close() error                { return nil }
                    """)
                == "10:18: cannot use &mock{} (value of type *mock) as net.Conn value in variable declaration: *mock does not implement net.Conn (missing method LocalAddr)")
        #expect(
            firstError(
                """
                var c net.Conn = 5
                fmt.Println(c)
                """,
                imports: ["fmt", "net"])
                == "6:18: cannot use 5 (constant of type int) as net.Conn value in variable declaration: int does not implement net.Conn (missing method Close)")
        #expect(
            firstError(
                """
                var l net.Listener = "x"
                fmt.Println(l)
                """,
                imports: ["fmt", "net"])
                == "6:22: cannot use \"x\" (constant of type string) as net.Listener value in variable declaration: string does not implement net.Listener (missing method Accept)")
        #expect(
            firstError(
                """
                var c net.Conn
                var l net.Listener = c
                fmt.Println(l)
                """,
                imports: ["fmt", "net"])
                == "7:22: cannot use c (variable of interface type net.Conn) as net.Listener value in variable declaration: net.Conn does not implement net.Listener (missing method Accept)")
        #expect(
            firstError(
                """
                var c net.Conn
                var r io.Reader = c
                var back net.Conn = r
                fmt.Println(back)
                """,
                imports: ["fmt", "io", "net"])
                == "9:21: cannot use r (variable of interface type io.Reader) as net.Conn value in variable declaration: io.Reader does not implement net.Conn (missing method Close)")
        #expect(
            firstError(
                """
                var c net.Conn
                fmt.Println(c.Foo())
                """,
                imports: ["fmt", "net"])
                == "7:15: c.Foo undefined (type net.Conn has no field or method Foo)")
        #expect(
            firstError(
                """
                var c net.Conn
                n := c.Read(make([]byte, 1))
                fmt.Println(n)
                """,
                imports: ["fmt", "net"])
                == "7:6: assignment mismatch: 1 variable but c.Read returns 2 values")
        #expect(
            firstError(
                """
                var c net.Conn
                c.Read("x")
                """,
                imports: ["fmt", "net"])
                == "7:8: cannot use \"x\" (untyped string constant) as []byte value in argument to c.Read")
        #expect(
            firstError(
                """
                var c net.Conn
                c.Close(1)
                """,
                imports: ["fmt", "net"])
                == "7:9: too many arguments in call to c.Close\n\thave (number)\n\twant ()")
        #expect(
            firstError(
                """
                var c net.Conn
                var f *os.File = c
                fmt.Println(f)
                """,
                imports: ["fmt", "net", "os"])
                == "8:18: cannot use c (variable of interface type net.Conn) as *os.File value in variable declaration")
        #expect(
            firstError(
                """
                var f *os.File
                var c closer = f
                fmt.Println(c)
                """,
                imports: ["fmt", "io", "os"],
                declarations: "type closer interface{ Close() }")
                == "8:16: cannot use f (variable of type *os.File) as closer value in variable declaration: *os.File does not implement closer (wrong type for method Close)\n\t\thave Close() error\n\t\twant Close()")
        #expect(
            firstError(
                """
                var conn net.Conn
                var c closer = conn
                fmt.Println(c)
                """,
                imports: ["fmt", "net"],
                declarations: "type closer interface{ Close() }")
                == "7:16: cannot use conn (variable of interface type net.Conn) as closer value in variable declaration: net.Conn does not implement closer (wrong type for method Close)\n\t\thave Close() error\n\t\twant Close()")
        #expect(
            firstError(
                """
                w := wrapped{os.Stdout}
                n := w.Write([]byte("x"))
                fmt.Println(n)
                """,
                imports: ["fmt", "io", "os"],
                declarations: """
                    type wrapped struct {
                        io.Writer
                    }
                    """)
                == "10:6: assignment mismatch: 1 variable but w.Write returns 2 values")
    }

    /// A call of a `net.Conn` method goes through the interface, `net.Conn`
    /// being Go text now, and a value converted to an interface is boxed with
    /// nothing. What looks a method up by
    /// the name of the dynamic type finds a function of the VM.
    @Test func theVMNamesWhatAHandleHoldsAndHasItsMethods() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(
                    """
                    var conn net.Conn
                    var r io.Reader = conn
                    if conn != nil {
                        conn.Read(make([]byte, 1))
                        conn.Close()
                    }
                    fmt.Println(r == nil)
                    """, imports: ["fmt", "io", "net"]))
        ])
        let main = try #require(executable.functions.first { $0.name == "main" })

        #expect(main.instructions.contains(.callInterface("Read", argumentCount: 1)))
        #expect(main.instructions.contains(.callInterface("Close", argumentCount: 0)))
        #expect(!main.instructions.contains { instruction in
            if case .makeInterface = instruction { return true }
            return false
        })
        #expect(
            GoLibraryMethods.handleFunctions.keys.sorted() == [
                "*net.TCPConn.Close", "*net.TCPConn.Read", "*net.TCPConn.Write",
                "*net.TCPListener.Accept", "*net.TCPListener.Close", "*os.File.Close",
                "*os.File.Read", "*os.File.ReadAt", "*os.File.Seek", "*os.File.Sync",
                "*os.File.Write", "*os.File.WriteAt", "*os.File.WriteString",
            ])
        let read = try #require(GoLibraryMethods.functions["*net.TCPConn.Read"])
        #expect(read.instructions == [.load(0), .load(1), .netRead, .returnValues(count: 2)])
        let write = try #require(GoLibraryMethods.functions["*os.File.Write"])
        #expect(
            write.instructions == [
                .load(0), .load(1), .call("$os.File.Write", argumentCount: 2),
                .returnValues(count: 2),
            ])
        #expect(GoTypeDescriptor.methodOwner(ofTypeName: "$T*O7:os.File") == "*os.File")
        #expect(
            GoTypeDescriptor.identity(ofTypeName: "*os.File")
                == GoTypeDescriptor.identity(ofTypeName: "$T*O7:os.File"))
        let target = try #require(GoErrors.InterfaceTarget("$IClose:0:1,Read:1:2,Write:1:2;net.Conn"))
        #expect(GoLibraryMethods.implements("*net.TCPConn", target))
        #expect(!GoLibraryMethods.implements("*os.File", target))
        let closer = try #require(GoErrors.InterfaceTarget("$IClose:0:1;"))
        #expect(GoLibraryMethods.implements("*os.File", closer))
        #expect(GoLibraryMethods.implements("*net.TCPListener", closer))
        #expect(!GoLibraryMethods.implements("main.mock", closer))
    }
}
