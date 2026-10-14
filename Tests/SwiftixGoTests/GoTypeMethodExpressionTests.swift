/// Method expressions of the types the program does not declare with
/// methods: the types of the run-time library (`time.Duration.String`,
/// `(*time.Time).Year`, `(*sync.Mutex).Lock`) and interface types (`I.m`,
/// `error.Error`, `fmt.Stringer.String`), with Go's types and Go's errors.
///
/// Each is a function the compiler synthesizes that takes the receiver
/// first: the one a method value of the type calls through. Every expected
/// output and error here was taken from Go 1.24.5.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go method expressions of library and interface types")
struct GoTypeMethodExpressionTests: GoTestHarness {

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

    /// A method of `time.Duration` and `time.Time` as a function, assigned,
    /// called where it is written, and printed by its type.
    @Test func methodExpressionsOfTimeTypes() throws {
        #expect(
            try runGoMain(
                #"""
                ds := time.Duration.String
                fmt.Println(ds(1500*time.Millisecond), time.Duration.Seconds(3*time.Second))
                fmt.Printf("%T %T\n", ds, time.Duration.Round)
                t := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
                y := time.Time.Year
                fmt.Println(y(t), time.Time.Month(t), time.Time.Add(t, time.Hour).Hour())
                py := (*time.Time).Year
                fmt.Println(py(&t))
                fmt.Printf("%T %T %T\n", y, py, time.Time.Add)
                """#,
                imports: ["fmt", "time"])
                == """
                1.5s 3
                func(time.Duration) string func(time.Duration, time.Duration) time.Duration
                2020 January 4
                2020
                func(time.Time) int func(*time.Time) int func(time.Time, time.Duration) time.Time

                """)
    }

    /// The methods of a type that must not be copied are its pointer's:
    /// `(*sync.Mutex).Lock` is a function of a `*sync.Mutex`, and so are those of
    /// `bytes.Buffer` and `strings.Builder`.
    @Test func methodExpressionsOfLibraryPointerTypes() throws {
        #expect(
            try runGoMain(
                #"""
                var mu sync.Mutex
                lock, unlock := (*sync.Mutex).Lock, (*sync.Mutex).Unlock
                lock(&mu)
                fmt.Println(mu.TryLock())
                unlock(&mu)
                fmt.Println(mu.TryLock())
                var rw sync.RWMutex
                (*sync.RWMutex).RLock(&rw)
                (*sync.RWMutex).RUnlock(&rw)
                fmt.Printf("%T %T\n", lock, (*sync.RWMutex).RLock)
                w := (*bytes.Buffer).Write
                var b bytes.Buffer
                n, err := w(&b, []byte("hi"))
                fmt.Println(n, err, b.String())
                ws := (*strings.Builder).WriteString
                var sb strings.Builder
                ws(&sb, "abc")
                fmt.Println(sb.String(), (*strings.Builder).Len(&sb))
                fmt.Printf("%T %T\n", w, ws)
                """#,
                imports: ["bytes", "fmt", "strings", "sync"])
                == """
                false
                true
                func(*sync.Mutex) func(*sync.RWMutex)
                2 <nil> hi
                abc 3
                func(*bytes.Buffer, []uint8) (int, error) func(*strings.Builder, string) (int, error)

                """)
    }

    /// `I.m` takes a value of the interface and calls the method of whatever it
    /// holds: of a program interface, of one it embeds, of `error`, of the
    /// library's interfaces, and of one a function declares. A nil interface
    /// panics when the method is called.
    @Test func methodExpressionsOfInterfaces() throws {
        #expect(
            try runGoMain(
                #"""
                im := I.M
                fmt.Println(im(T{1}, 2), I.M(T{3}, 4), J.M(T{5}, 1), J.N(T{7}))
                fmt.Printf("%T %T\n", im, J.N)
                e := error.Error
                fmt.Println(e(errors.New("x")))
                fmt.Printf("%T\n", e)
                n, err := io.Writer.Write(os.Stdout, []byte("hello\n"))
                fmt.Println(n, err)
                fmt.Printf("%T\n", io.Writer.Write)
                sm := fmt.Stringer.String
                fmt.Println(sm(time.Second), sm(T{4}))
                fmt.Printf("%T\n", sm)
                type local interface{ M(int) string }
                fmt.Println(local.M(T{2}, 2))
                var none I
                defer func() { fmt.Println("recovered:", recover()) }()
                fmt.Println(I.M(none, 1))
                """#,
                imports: ["errors", "fmt", "io", "os", "time"],
                declarations: """
                    type I interface{ M(int) string }

                    type J interface {
                        I
                        N() int
                    }

                    type T struct{ n int }

                    func (t T) M(x int) string { return fmt.Sprint(t.n + x) }
                    func (t T) N() int         { return t.n }
                    func (t T) String() string { return "T" }
                    """)
                == """
                3 7 6 7
                func(main.I, int) string func(main.J) int
                x
                func(error) string
                hello
                6 <nil>
                func(io.Writer, []uint8) (int, error)
                1s T
                func(fmt.Stringer) string
                4
                recovered: runtime error: invalid memory address or nil pointer dereference

                """)
    }

    /// An aliased import, a closure that captures one, and a context's `Err`.
    @Test func methodExpressionsThroughEveryPass() throws {
        #expect(
            try runGoMain(
                #"""
                d := t.Duration.String
                f := func() string { return d(3 * t.Second) }
                fmt.Println(f(), t.Duration.Minutes(90*t.Second))
                ctx, cancel := context.WithCancel(context.Background())
                cancel()
                fmt.Println(context.Context.Err(ctx))
                fmt.Printf("%T\n", context.Context.Err)
                """#,
                imports: ["context", "fmt"],
                declarations: "import t \"time\"")
                == "3s 1.5\ncontext canceled\nfunc(context.Context) error\n")
    }

    /// A type alias, at package level and in a function, of a library type
    /// and of a library interface.
    @Test func methodExpressionsThroughAliases() throws {
        #expect(
            try runGoMain(
                #"""
                type L = time.Time
                f := D.String
                fmt.Println(f(time.Second), S.String(time.Minute), L.Unix(time.Unix(5, 0)))
                fmt.Printf("%T %T\n", f, S.String)
                type E = error
                fmt.Println(E.Error(fmt.Errorf("e")), D.String(time.Hour))
                """#,
                imports: ["fmt", "time"],
                declarations: """
                    type D = time.Duration
                    type S = fmt.Stringer
                    """)
                == "1s 1m0s 5\nfunc(time.Duration) string func(fmt.Stringer) string\ne 1h0m0s\n")
    }

    /// An interface of another package of the module, and a constant of
    /// `time` it declares, under an aliased import.
    @Test func methodExpressionsAcrossPackages() throws {
        let executable = try GoCompiler.compile(
            packages: [
                GoPackageSource(
                    importPath: "example/m/lib",
                    sources: [
                        GoSourceFile(
                            path: "lib/lib.go",
                            text: """
                                package lib

                                import "time"

                                type Namer interface{ Name() string }

                                type Thing struct{ N string }

                                func (t Thing) Name() string { return t.N }

                                const Timeout = 3 * time.Second

                                const Big = Timeout * 1000
                                """)
                    ]),
                GoPackageSource(
                    importPath: "example/m",
                    sources: [
                        GoSourceFile(
                            path: "main.go",
                            text: """
                                package main

                                import (
                                    "example/m/lib"
                                    "fmt"
                                    tm "time"
                                )

                                const local = lib.Timeout + tm.Second

                                func main() {
                                    f := lib.Namer.Name
                                    fmt.Println(f(lib.Thing{"x"}), lib.Namer.Name(lib.Thing{"y"}))
                                    fmt.Printf("%T\\n", f)
                                    fmt.Println(local, lib.Big)
                                    g := func() func(tm.Duration) string { return tm.Duration.String }
                                    fmt.Println(g()(local))
                                }
                                """)
                    ]),
            ],
            root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(output == "x y\nfunc(lib.Namer) string\n4s 50m0s\n4s\n")
    }

    /// A method the type does not have, one only its pointer has, and a method of
    /// a pointer to an interface. Go 1.24 quotes the path of `sync` and
    /// `sync/atomic`, whose names other packages of its library share.
    @Test func methodExpressionsAreRefusedAsGoRefusesThem() {
        #expect(
            firstError("fmt.Println(time.Duration.Foo)", imports: ["fmt", "time"])
                == "6:27: time.Duration.Foo undefined (type time.Duration has no field or method Foo)")
        #expect(
            firstError("fmt.Println((*time.Time).Foo)", imports: ["fmt", "time"])
                == "6:26: (*time.Time).Foo undefined (type *time.Time has no field or method Foo)")
        #expect(
            firstError("fmt.Println(sync.Mutex.Lock)", imports: ["fmt", "sync"])
                == "6:24: invalid method expression \"sync\".Mutex.Lock (needs pointer receiver (*\"sync\".Mutex).Lock)")
        #expect(
            firstError("fmt.Println(sync.WaitGroup.Wait)", imports: ["fmt", "sync"])
                == "6:28: invalid method expression \"sync\".WaitGroup.Wait (needs pointer receiver (*\"sync\".WaitGroup).Wait)")
        #expect(
            firstError("fmt.Println(sync.RWMutex.RLock)", imports: ["fmt", "sync"])
                == "6:26: invalid method expression \"sync\".RWMutex.RLock (needs pointer receiver (*\"sync\".RWMutex).RLock)")
        #expect(
            firstError("fmt.Println(sync.Once.Do)", imports: ["fmt", "sync"])
                == "6:23: invalid method expression \"sync\".Once.Do (needs pointer receiver (*\"sync\".Once).Do)")
        #expect(
            firstError("fmt.Println(atomic.Int64.Load)", imports: ["fmt", "sync/atomic"])
                == "6:26: invalid method expression \"sync/atomic\".Int64.Load (needs pointer receiver (*\"sync/atomic\".Int64).Load)")
        #expect(
            firstError("fmt.Println(bytes.Buffer.Write)", imports: ["bytes", "fmt"])
                == "6:26: invalid method expression bytes.Buffer.Write (needs pointer receiver (*bytes.Buffer).Write)")
        #expect(
            firstError("fmt.Println((*I).M)", imports: ["fmt"],
                declarations: "type I interface{ M() }")
                == "5:18: (*I).M undefined (type *I is pointer to interface, not interface)")
        #expect(
            firstError("fmt.Println(time.Time.Year())", imports: ["fmt", "time"])
                == "6:13: not enough arguments in call to time.Time.Year\n\thave ()\n\twant (time.Time)")
        #expect(
            firstError(
                """
                var f func(time.Duration) int = time.Duration.String
                fmt.Println(f)
                """,
                imports: ["fmt", "time"])
                == "6:33: cannot use time.Duration.String (value of type func(time.Duration) string) as func(time.Duration) int value in variable declaration")
    }
}
