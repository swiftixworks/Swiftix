/// `log`, `sync/atomic`, `sync.Map`, and `sync.Pool` as parts of a program:
/// what the standard logger writes when nothing was set, how `Fatal` ends a
/// program, a module whose packages share them under names of their own,
/// and what a program is linked with.
///
/// The packages are Go text of the library (`GoSourceLibrary`). What the
/// module prints is what Go 1.24.5 prints for it. The lines with a date are
/// this run-time's: its clock is logical and starts at the Unix epoch, where
/// Go's is the host's, and the layout is held to Go's by
/// `Scripts/go-library-harness/run.sh log`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go log and sync in a program")
struct GoLogProgramTests: GoTestHarness {

    /// The names of the functions of the image `body` compiles to, as the
    /// body of `func main`.
    private func functionNames(
        _ body: String, imports: [String], declarations: String = ""
    ) throws -> Set<String> {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(body, imports: imports, declarations: declarations))
        ])
        return Set(executable.functions.map(\.name))
    }

    /// The standard logger starts with the date and the time, in Go's
    /// layout, and writes to standard error. The clock of a run starts at
    /// the epoch and follows `time.Sleep`. A file and line are what Go
    /// prints when it cannot tell them, which here is always.
    @Test func theStandardLoggerWritesTheDateAndTime() throws {
        #expect(
            try runGoMain(
                """
                log.Print("default")
                log.SetPrefix("p ")
                log.SetFlags(log.LstdFlags | log.Lmicroseconds | log.Lmsgprefix)
                time.Sleep(1500 * time.Millisecond)
                log.Print("later")
                log.SetFlags(log.Ltime | log.LUTC)
                time.Sleep(26*time.Hour + 61*time.Second)
                log.Print("time alone")
                log.SetFlags(log.Ldate)
                log.Print("date alone")
                log.SetFlags(log.Lshortfile)
                log.Print("no file")
                """, imports: ["log", "time"])
                == """
                1970/01/01 00:00:00 default
                1970/01/01 00:00:01.500000 p later
                p 02:01:02 time alone
                p 1970/01/02 date alone
                p ???:0: no file

                """)
    }

    /// `Fatal`, `Fatalf`, and `Fatalln` write the line and end the program
    /// with status 1, without running deferred calls.
    @Test func fatalWritesAndExitsWithStatusOne() throws {
        for (call, line) in [
            (#"log.Fatal("gone", 1, 2)"#, "x: gone1 2\n"),
            (#"log.Fatalf("gone %d", 1)"#, "x: gone 1\n"),
            (#"log.Fatalln("gone", 1)"#, "x: gone 1\n"),
            (#"log.New(log.Writer(), "l: ", 0).Fatalf("gone %d", 2)"#, "l: gone 2\n"),
            (#"log.Default().Fatal("gone")"#, "x: gone\n"),
            (#"log.Default().Fatalln("gone")"#, "x: gone\n"),
        ] {
            let executable = try GoCompiler.compile(sources: [
                GoSourceFile(
                    path: "main.go",
                    text: goMainSource(
                        """
                        defer fmt.Println("a deferred call does not run")
                        log.SetFlags(0)
                        log.SetPrefix("x: ")
                        log.Println("before")
                        \(call)
                        fmt.Println("not reached")
                        """, imports: ["fmt", "log"]))
            ])
            var output = ""
            let status = try GoVirtualMachine().run(executable) { output += $0 }
            #expect(output == "x: before\n" + line)
            #expect(status == 1)
        }
    }

    /// Two packages of a module use the packages, one of them under names
    /// of its own (`import l "log"`, `a "sync/atomic"`, `s "sync"`), as
    /// fields of an exported type the other reaches into.
    @Test func aModuleSharesThemAcrossPackages() throws {
        let packages = [
            GoPackageSource(
                importPath: "example/m",
                sources: [
                    GoSourceFile(
                        path: "/m/main.go",
                        text: """
                            package main

                            import (
                                "fmt"
                                "log"
                                "sync"
                                "sync/atomic"

                                "example/m/svc"
                            )

                            func main() {
                                service := svc.New("api")
                                var wg sync.WaitGroup
                                var sum atomic.Int64
                                for _, who := range []string{"ann", "bob", "ann"} {
                                    wg.Add(1)
                                    go func() {
                                        defer wg.Done()
                                        sum.Add(service.Handle(who))
                                    }()
                                    wg.Wait()
                                }
                                names := 0
                                service.Seen.Range(func(key, value any) bool {
                                    names++
                                    return true
                                })
                                var logger *log.Logger = service.Log
                                logger.Println(names, "names,", service.Requests.Load(), "requests")
                                fmt.Println(sum.Load(), logger.Prefix())
                            }
                            """)
                ]),
            GoPackageSource(
                importPath: "example/m/svc",
                sources: [
                    GoSourceFile(
                        path: "/m/svc/svc.go",
                        text: """
                            package svc

                            import (
                                "fmt"
                                l "log"
                                s "sync"
                                a "sync/atomic"
                            )

                            type out struct{}

                            func (out) Write(p []byte) (int, error) {
                                fmt.Print(string(p))
                                return len(p), nil
                            }

                            // Service counts requests and remembers who made them.
                            type Service struct {
                                Requests a.Int64
                                Seen     s.Map
                                Log      *l.Logger
                                buffers  s.Pool
                                total    int64
                            }

                            func New(name string) *Service {
                                v := &Service{Log: l.New(out{}, "["+name+"] ", l.Lmsgprefix)}
                                v.buffers.New = func() any { return []string{} }
                                return v
                            }

                            func (v *Service) Handle(who string) int64 {
                                parts := v.buffers.Get().([]string)
                                parts = append(parts, who)
                                defer v.buffers.Put(parts[:0])
                                v.Seen.LoadOrStore(who, len(parts))
                                a.AddInt64(&v.total, 2)
                                n := v.Requests.Add(1)
                                v.Log.Printf("%s is request %d", parts[0], n)
                                return a.LoadInt64(&v.total)
                            }
                            """)
                ]),
        ]
        let executable = try GoCompiler.compile(packages: packages, root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(
            output == """
                [api] ann is request 1
                [api] bob is request 2
                [api] ann is request 3
                [api] 2 names, 3 requests
                12 [api]\u{20}

                """)
    }

    /// A program pays for what it reaches: one function of `sync/atomic`
    /// brings that function, a typed value its methods and the functions
    /// they call, and `sync.Mutex` alone, which is native, nothing.
    @Test func onlyWhatAProgramUsesIsLinked() throws {
        let add = try functionNames(
            "var n int64\nfmt.Println(atomic.AddInt64(&n, 1))", imports: ["fmt", "sync/atomic"])
        #expect(add == ["main", "sync/atomic.AddInt64", "$sync/atomic.init"])

        let typed = try functionNames(
            "var n atomic.Bool\nn.Store(true)", imports: ["sync/atomic"])
        #expect(typed.filter { $0.contains("Int") || $0.contains("Value") }.isEmpty)
        #expect(typed.contains("*sync/atomic.Bool.Store"))

        let pool = try functionNames(
            "var p sync.Pool\np.Put(1)\nvar mu sync.Mutex\nmu.Lock()", imports: ["sync"])
        #expect(pool == ["main", "*sync.Pool.Get", "*sync.Pool.Put"])

        let logged = try functionNames(#"log.Print("x")"#, imports: ["log"])
        #expect(logged.contains("log.Print"))
        #expect(!logged.contains("log.Printf"))
        #expect(logged.filter { $0.hasPrefix("sync") || $0.hasPrefix("*sync") }.isEmpty)

        let none = try functionNames(
            "var mu sync.Mutex\nmu.Lock()\nvar wg sync.WaitGroup\nwg.Wait()", imports: ["sync"])
        #expect(none == ["main"])
    }
}
