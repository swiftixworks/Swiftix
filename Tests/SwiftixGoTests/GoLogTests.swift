/// `log`: a `Logger` writes each message as one line to its writer, after
/// the prefix and the date and time its flags ask for.
///
/// The package is Go text of the library (`Sources/SwiftixGoLibrary/log`),
/// compiled with the program that uses it. What each program prints is what
/// Go 1.24.5 prints for it, with the date and time off, since Go's clock is
/// the host's; the date and time of a line are held to Go's at 400,000
/// instants by `Scripts/go-library-harness/run.sh log`, which runs the text
/// in real Go, and pinned here at the instants the logical clock of a run
/// starts from. The programs write through a writer of their own to
/// standard output, which is what the tests read; the standard logger's own
/// writer is standard error.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go log")
struct GoLogTests: GoTestHarness {

    /// `Print`, `Println`, and `Printf` format as their namesakes of `fmt`, and
    /// a line ends in exactly the newlines its message has, or one.
    @Test func theStandardLoggerWritesOneLineForEachCall() throws {
        #expect(
            try runGoMain(
                #"""
                log.SetOutput(stdout{})
                fmt.Println(log.Flags() == log.LstdFlags, log.Prefix() == "")
                fmt.Println(log.Ldate, log.Ltime, log.Lmicroseconds, log.Llongfile, log.Lshortfile, log.LUTC, log.Lmsgprefix, log.LstdFlags)
                log.SetFlags(0)
                log.Print("plain", 1, 2, "x", "y", 3.5)
                log.Println("line", 1, true)
                log.Printf("%d-%s|%v\n", 7, "f", []int{1})
                log.Print("ends\n")
                log.Print("")
                log.Print("two\n\n")
                log.SetPrefix("[srv] ")
                log.Printf("with prefix %q", log.Prefix())
                log.SetFlags(log.Lmsgprefix)
                log.Println("the prefix goes before the message")
                fmt.Println(log.Flags(), log.Output(1, "direct"))
                """#,
                imports: ["fmt", "log"],
                declarations: """
                    type stdout struct{}

                    func (stdout) Write(p []byte) (int, error) {
                        fmt.Print(string(p))
                        return len(p), nil
                    }
                    """)
                == """
                true true
                1 2 4 8 16 32 64 3
                plain1 2xy3.5
                line 1 true
                7-f|[1]
                ends

                two

                [srv] with prefix "[srv] "
                [srv] the prefix goes before the message
                [srv] direct
                64 <nil>

                """)
    }

    /// `log.New` makes a logger of a writer; its methods are those of the package,
    /// and each call is one `Write`. `Output` returns the error of the writer.
    @Test func aLoggerHasItsOwnWriterPrefixAndFlags() throws {
        #expect(
            try runGoMain(
                #"""
                b := &lines{}
                var w io.Writer = b
                l := log.New(b, "p: ", 0)
                l.Print("a")
                l.Println("b", 2)
                l.Printf("c%d", 3)
                fmt.Println(l.Output(1, "direct"), l.Prefix(), l.Flags())
                l.SetPrefix("q: ")
                l.SetFlags(log.Lmsgprefix)
                l.Print("d")
                fmt.Printf("%q\n", b.written)
                fmt.Println(l.Writer() == w)
                l.SetOutput(failing{})
                fmt.Println(l.Output(1, "x"))
                log.SetOutput(b)
                log.SetFlags(0)
                log.Print("to the same writer")
                fmt.Println(len(b.written), log.Writer() == w, log.Default() == log.Default())
                d := log.Default()
                d.SetPrefix("D ")
                log.Print("through Default")
                fmt.Printf("%q %T %T\n", b.written[len(b.written)-1], d, l)
                discard := log.New(io.Discard, "", log.LstdFlags)
                discard.Print("nowhere")
                """#,
                imports: ["errors", "fmt", "io", "log"],
                declarations: """
                    type lines struct{ written []string }

                    func (l *lines) Write(p []byte) (int, error) {
                        l.written = append(l.written, string(p))
                        return len(p), nil
                    }

                    type failing struct{}

                    func (failing) Write(p []byte) (int, error) { return 0, errors.New("disk full") }
                    """)
                == #"""
                <nil> p:  0
                ["p: a\n" "p: b 2\n" "p: c3\n" "p: direct\n" "q: d\n"]
                true
                disk full
                6 true true
                "D through Default\n" *log.Logger *log.Logger

                """#)
    }

    /// `Panic`, `Panicf`, and `Panicln` write the line and panic with the message
    /// as a string, which `recover` returns.
    @Test func panicWritesAndThenPanicsWithTheMessage() throws {
        #expect(
            try runGoMain(
                #"""
                b := &lines{}
                l := log.New(b, "q: ", 0)
                log.SetOutput(b)
                log.SetFlags(0)
                try := func(f func()) {
                    defer func() { fmt.Printf("recovered %q\n", recover()) }()
                    f()
                }
                try(func() { log.Panicf("bad %d", 9) })
                try(func() { log.Panicln("bad", 9) })
                try(func() { log.Panic("bad", 9) })
                try(func() { l.Panicf("bad %d", 9) })
                try(func() { l.Panicln("bad", 9) })
                try(func() { l.Panic("bad", 9) })
                fmt.Printf("%q\n", b.written)
                """#,
                imports: ["fmt", "log"],
                declarations: """
                    type lines struct{ written []string }

                    func (l *lines) Write(p []byte) (int, error) {
                        l.written = append(l.written, string(p))
                        return len(p), nil
                    }
                    """)
                == #"""
                recovered "bad 9"
                recovered "bad 9\n"
                recovered "bad9"
                recovered "bad 9"
                recovered "bad 9\n"
                recovered "bad9"
                ["bad 9\n" "bad 9\n" "bad9\n" "q: bad 9\n" "q: bad 9\n" "q: bad9\n"]

                """#)
    }

    /// A function of the package and a method of a logger are values like any
    /// other of the program, a logger is a field and a parameter, and a type
    /// declared in a function is a writer.
    @Test func theFunctionsAndMethodsAreValues() throws {
        #expect(
            try runGoMain(
                """
                type upper struct{ n int }
                type sink = stdout
                s := &server{name: "s1", log: log.New(sink{}, "[s1] ", log.Lmsgprefix)}
                s.handle("GET /")
                printf := s.log.Printf
                printf("bound %d", 1)
                log.SetOutput(stdout{})
                log.SetFlags(0)
                say := log.Println
                say("as", "a", "value")
                for i, f := range []func(...any){log.Print, s.log.Print} {
                    f("call ", i)
                }
                count := 0
                each := func(l *log.Logger, words ...string) {
                    for _, word := range words {
                        count++
                        l.Printf("%d %s", count, word)
                    }
                }
                each(s.log, "x", "y")
                each(log.Default(), "z")
                fmt.Println(count, upper{1})
                """,
                imports: ["fmt", "log"],
                declarations: """
                    type stdout struct{}

                    func (stdout) Write(p []byte) (int, error) {
                        fmt.Print(string(p))
                        return len(p), nil
                    }

                    type server struct {
                        name string
                        log  *log.Logger
                    }

                    func (s *server) handle(request string) {
                        s.log.Printf("%s: %s", s.name, request)
                    }
                    """)
                == """
                [s1] s1: GET /
                [s1] bound 1
                as a value
                call 0
                [s1] call 1
                [s1] 1 x
                [s1] 2 y
                3 z
                3 {1}

                """)
    }

    /// Each line reaches the writer whole, whichever goroutine wrote it.
    @Test func linesOfGoroutinesDoNotInterleave() throws {
        #expect(
            try runGoMain(
                #"""
                b := &lines{}
                l := log.New(b, "", 0)
                var wg sync.WaitGroup
                for g := 0; g < 4; g++ {
                    wg.Add(1)
                    go func() {
                        defer wg.Done()
                        for i := 0; i < 25; i++ {
                            l.Printf("goroutine %d line %d", g, i)
                        }
                    }()
                }
                wg.Wait()
                whole := 0
                for _, line := range b.written {
                    if strings.HasPrefix(line, "goroutine ") && strings.Count(line, "\n") == 1 && strings.HasSuffix(line, "\n") {
                        whole++
                    }
                }
                fmt.Println(len(b.written), whole)
                """#,
                imports: ["fmt", "log", "strings", "sync"],
                declarations: """
                    type lines struct{ written []string }

                    func (l *lines) Write(p []byte) (int, error) {
                        l.written = append(l.written, string(p))
                        return len(p), nil
                    }
                    """)
                == "100 100\n")
    }
}
