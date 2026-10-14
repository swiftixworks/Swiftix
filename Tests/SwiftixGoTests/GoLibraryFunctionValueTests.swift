/// Functions of the run-time library as values: `f := strings.ToUpper`,
/// `apply(strings.TrimSpace, s)`, `done := wg.Done`.
///
/// Functions of the program as values are in `GoFunctionValueTests`. What
/// each program prints is what Go 1.24.5 prints for it; a message pinned
/// alone is one this dialect words in its own way, as it does for a function
/// of the program.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go library function values")
struct GoLibraryFunctionValueTests: GoTestHarness {

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

    /// Named without a call it is assigned, passed, returned, stored, compared
    /// with `nil`, and called through whatever holds it.
    @Test func aLibraryFunctionIsAValueOfItsType() throws {
        #expect(
            try runGoMain(
                """
                f := strings.ToUpper
                fmt.Println(f("x"), apply(strings.TrimSpace, "  padded  ")+"|", pick(true)("Abc"), pick(false)("Abc"))
                steps := []func(string) string{strings.TrimSpace, strings.ToUpper}
                s := "  hello "
                for _, step := range steps {
                    s = step(s)
                }
                table := map[string]func(string) string{"lower": strings.ToLower, "trim": strings.TrimSpace}
                c := conv{"upper", strings.ToUpper}
                fmt.Println(s, table["lower"]("ABC"), table["trim"](" x ")+"|", c.name, c.run("abc"))
                var g func(string) string
                fmt.Println(f != nil, g == nil, strings.ToUpper != nil)
                g = strings.ToLower
                fmt.Println(g == nil, g("Q"), upper("global"), compose(strings.TrimSpace, strings.ToUpper)("  hey "))
                jobs := make(chan func(string) string, 1)
                jobs <- strings.ToUpper
                fmt.Println((<-jobs)("through a channel"))
                """,
                imports: ["fmt", "strings"],
                declarations: """
                    type conv struct {
                        name string
                        run  func(string) string
                    }

                    var upper = strings.ToUpper

                    func apply(f func(string) string, s string) string { return f(s) }

                    func pick(upper bool) func(string) string {
                        if upper {
                            return strings.ToUpper
                        }
                        return strings.ToLower
                    }

                    func compose(f, g func(string) string) func(string) string {
                        return func(s string) string { return g(f(s)) }
                    }
                    """)
                == """
                X padded| ABC abc
                HELLO abc x| upper ABC
                true true true
                false q GLOBAL HEY
                THROUGH A CHANNEL

                """)
    }

    /// `%T` of a library function is its Go signature, whatever the VM runs
    /// for it: an instruction, a native call, or Go text of the library.
    @Test func itPrintsTheTypeGoDeclares() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Printf("%T\n%T\n%T\n%T\n", fmt.Print, fmt.Println, fmt.Printf, fmt.Errorf)
                fmt.Printf("%T\n%T\n%T\n", fmt.Sprint, fmt.Sprintln, fmt.Sprintf)
                fmt.Printf("%T\n%T\n", strconv.Atoi, strconv.Itoa)
                fmt.Printf("%T\n%T\n%T\n", errors.New, errors.Is, errors.Unwrap)
                fmt.Printf("%T\n%T\n", sort.Strings, sort.Ints)
                fmt.Printf("%T\n%T\n%T\n%T\n", os.Open, os.Create, os.ReadFile, os.Exit)
                fmt.Printf("%T\n%T\n", os.Remove, os.Rename)
                """#,
                imports: ["errors", "fmt", "os", "sort", "strconv"])
                == """
                func(...interface {}) (int, error)
                func(...interface {}) (int, error)
                func(string, ...interface {}) (int, error)
                func(string, ...interface {}) error
                func(...interface {}) string
                func(...interface {}) string
                func(string, ...interface {}) string
                func(string) (int, error)
                func(int) string
                func(string) error
                func(error, error) bool
                func(error) error
                func([]string)
                func([]int)
                func(string) (*os.File, error)
                func(string) (*os.File, error)
                func(string) ([]uint8, error)
                func(int)
                func(string) error
                func(string, string) error

                """)
        #expect(
            try runGoMain(
                #"""
                fmt.Printf("%T\n%T\n%T\n%T\n%T\n", strings.Contains, strings.Count, strings.Fields, strings.HasPrefix, strings.HasSuffix)
                fmt.Printf("%T\n%T\n%T\n%T\n%T\n", strings.Index, strings.Join, strings.LastIndex, strings.Repeat, strings.Split)
                fmt.Printf("%T\n%T\n%T\n%T\n%T\n", strings.ToLower, strings.ToUpper, strings.TrimPrefix, strings.TrimSpace, strings.TrimSuffix)
                fmt.Printf("%T\n%T\n%T\n", context.Background, context.WithCancel, time.Now)
                fmt.Printf("%T\n%T\n%T\n%T\n", net.Dial, net.Listen, net.LookupHost, runtime.GC)
                """#,
                imports: ["context", "fmt", "net", "runtime", "strings", "time"])
                == """
                func(string, string) bool
                func(string, string) int
                func(string) []string
                func(string, string) bool
                func(string, string) bool
                func(string, string) int
                func([]string, string) string
                func(string, string) int
                func(string, int) string
                func(string, string) []string
                func(string) string
                func(string) string
                func(string, string) string
                func(string) string
                func(string, string) string
                func() context.Context
                func(context.Context) (context.Context, context.CancelFunc)
                func() time.Time
                func(string, string) (net.Conn, error)
                func(string, string) (net.Listener, error)
                func(string) ([]string, error)
                func()

                """)
    }

    /// Each gives through a value what it gives when called by name.
    @Test func everyStringsFunctionIsCalledThroughAValue() throws {
        #expect(
            try runGoMain(
                """
                contains, count, fields, hasPrefix := strings.Contains, strings.Count, strings.Fields, strings.HasPrefix
                hasSuffix, index, join, lastIndex := strings.HasSuffix, strings.Index, strings.Join, strings.LastIndex
                repeat, split, toLower, toUpper := strings.Repeat, strings.Split, strings.ToLower, strings.ToUpper
                trimPrefix, trimSpace, trimSuffix := strings.TrimPrefix, strings.TrimSpace, strings.TrimSuffix
                fmt.Println(contains("abc", "b"), count("aaa", "a"), fields(" a b "), hasPrefix("ab", "a"),
                    hasSuffix("ab", "b"), index("abc", "c"), join([]string{"a", "b"}, "-"), lastIndex("aba", "a"))
                fmt.Println(repeat("ab", 2), split("a,b", ","), toLower("AB"), toUpper("ab"), trimPrefix("ab", "a"),
                    trimSpace(" a ")+"|", trimSuffix("ab", "b"))
                """,
                imports: ["fmt", "strings"])
                == "true 3 [a b] true true 2 a-b 2\nabab [a b] ab AB b a| a\n")
    }

    /// `fmt.Println` as a value is a `func(...interface {}) (int, error)`: it
    /// formats each operand by its type, and takes a `[]interface{}` with `...`.
    @Test func variadicOnesTakeAnyNumberOfOperandsAndASlice() throws {
        #expect(
            try runGoMain(
                #"""
                p := fmt.Println
                n, err := p("a", 1, true, point{1, 2}, []string{"x"})
                fmt.Println(n, err)
                p()
                args := []interface{}{"x", 2, byte(7)}
                p(args...)
                sp := fmt.Sprintf
                fmt.Println(sp("%d-%s-%v", 7, "z", point{3, 4}), sp("plain"), sp("%v|%v|%T", args...))
                var printers []func(...interface{}) (int, error)
                printers = append(printers, fmt.Print, fmt.Println)
                for _, print := range printers {
                    print("x", "y", 1, 2)
                }
                logf := fmt.Printf
                count, err := logf("%s=%d\n", "k", 5)
                fmt.Println(count, err)
                sprint, sprintln := fmt.Sprint, fmt.Sprintln
                fmt.Print(sprint("a", 1, 2, "b"), "|", sprintln("a", 1))
                wrap := fmt.Errorf
                base := errors.New("base")
                wrapped := wrap("wrapped: %w", base)
                is, unwrap := errors.Is, errors.Unwrap
                fmt.Println(wrapped, is(wrapped, base), unwrap(wrapped) == base)
                fprint := fmt.Fprintln
                fprint(os.Stdout, "to", "stdout", 3)
                """#,
                imports: ["errors", "fmt", "os"],
                declarations: "type point struct{ x, y int }")
                == """
                a 1 true {1 2} [x]
                19 <nil>

                x 2 7
                7-z-{3 4} plain x|2|uint8
                xy1 2x y 1 2
                k=5
                4 <nil>
                a1 2b|a 1
                wrapped: base true true
                to stdout 3

                """)
    }

    /// `strconv.Atoi` as a value returns its number and its error.
    @Test func severalResultsComeThroughTheValue() throws {
        #expect(
            try runGoMain(
                """
                atoi := strconv.Atoi
                v, err := atoi("42")
                fmt.Println(v, err)
                _, err = atoi("x")
                fmt.Println(err)
                sum, err := parseAll(strconv.Atoi, "1", "2", "3")
                fmt.Println(sum, err)
                sum, err = parseAll(strconv.Atoi, "1", "x")
                fmt.Println(sum, err)
                itoa := strconv.Itoa
                fmt.Println(itoa(12) + itoa(34))
                mk := errors.New
                fmt.Println(mk("boom"))
                names := []string{"b", "a"}
                sortNames := sort.Strings
                sortNames(names)
                fmt.Println(names)
                """,
                imports: ["errors", "fmt", "sort", "strconv"],
                declarations: """
                    func parseAll(parse func(string) (int, error), inputs ...string) (int, error) {
                        sum := 0
                        for _, input := range inputs {
                            n, err := parse(input)
                            if err != nil {
                                return sum, err
                            }
                            sum += n
                        }
                        return sum, nil
                    }
                    """)
                == """
                42 <nil>
                strconv.Atoi: parsing "x": invalid syntax
                6 <nil>
                1 strconv.Atoi: parsing "x": invalid syntax
                1234
                boom
                [a b]

                """)
    }

    /// `wg.Done`, `mu.Unlock`, and `os.Stdout.WriteString` are functions that
    /// have their receiver, like a method value of a type of the program.
    @Test func aMethodOfALibraryTypeIsAValueThatHasItsReceiver() throws {
        #expect(
            try runGoMain(
                #"""
                var wg sync.WaitGroup
                var mu sync.Mutex
                add, done, wait := wg.Add, wg.Done, wg.Wait
                lock, unlock := mu.Lock, mu.Unlock
                total := 0
                for i := 1; i <= 4; i++ {
                    add(1)
                    go func() {
                        defer done()
                        lock()
                        defer unlock()
                        total += i
                    }()
                }
                wait()
                fmt.Println(total)
                fmt.Printf("%T %T %T %T\n", add, done, lock, wg.Wait)
                g := &guarded{}
                l, u := g.mu.Lock, g.mu.Unlock
                l()
                g.n++
                u()
                pm := &mu
                pl := pm.Lock
                pl()
                pm.Unlock()
                run(3, mu.Lock, mu.Unlock, func(i int) { g.n += i })
                fmt.Println(g.n)
                out := os.Stdout.WriteString
                n, err := out("direct\n")
                fmt.Println(n, err)
                fmt.Printf("%T %T %T\n", out, os.Stdout.Write, os.Stdout.Close)
                """#,
                imports: ["fmt", "os", "sync"],
                declarations: """
                    type guarded struct {
                        mu sync.Mutex
                        n  int
                    }

                    func run(n int, before, after func(), body func(int)) {
                        for i := 0; i < n; i++ {
                            before()
                            body(i)
                            after()
                        }
                    }
                    """)
                == """
                10
                func(int) func() func() func()
                4
                direct
                7 <nil>
                func(string) (int, error) func([]uint8) (int, error) func() error

                """)
        #expect(
            try runGoMain(
                #"""
                t := time.Unix(100, 5)
                nanos, before, after := t.UnixNano, t.Before, t.After
                t = time.Unix(900, 0)
                fmt.Println(nanos(), before(time.Unix(200, 0)), after(time.Unix(200, 0)), t.UnixNano())
                fmt.Printf("%T %T\n", before, t.Equal)
                ctx, cancel := context.WithCancel(context.Background())
                failure := ctx.Err
                fmt.Println(failure())
                cancel()
                fmt.Println(failure())
                fmt.Printf("%T\n", failure)
                """#,
                imports: ["context", "fmt", "time"])
                == """
                100000000005 true false 900000000000
                func(time.Time) bool func(time.Time) bool
                <nil>
                context canceled
                func() error

                """)
    }

    /// The value is read where the statement stands, and the call it names
    /// runs later.
    @Test func goAndDeferCallThroughALibraryValue() throws {
        #expect(
            try runGoMain(
                """
                p := fmt.Println
                defer p("deferred", 1)
                var wg sync.WaitGroup
                wg.Add(2)
                d := wg.Done
                go d()
                go func() {
                    defer d()
                    p("in a goroutine")
                }()
                wg.Wait()
                func() {
                    q := p
                    defer q("deferred in a literal")
                    q("called in a literal")
                }()
                p = nil
                fmt.Println(p == nil)
                """,
                imports: ["fmt", "sync"])
                == """
                in a goroutine
                called in a literal
                deferred in a literal
                true
                deferred 1

                """)
    }

    /// An import under another name, a dot import, a type declared in a
    /// function, an alias, and a literal that captures the value.
    @Test func everyPassSeesALibraryValue() throws {
        #expect(
            try runGoMain(
                """
                type step struct {
                    name string
                    run  func(string) string
                }
                type steps = []step
                all := steps{step{"upper", str.ToUpper}, step{"trim", str.TrimSpace}}
                s := " mixed Case "
                for _, each := range all {
                    s = each.run(s)
                }
                print := f.Println
                print(s + "|")
                var m mapper = str.ToLower
                shout := func(s string) string { return m(s) + "!" }
                m = str.ToUpper
                print(shout("captured"))
                print(f.Sprintf("%T %T", m, print))
                """,
                declarations: """
                    import (
                        f "fmt"
                        str "strings"
                    )

                    type mapper = func(string) string
                    """)
                == """
                MIXED CASE|
                CAPTURED!
                func(string) string func(...interface {}) (int, error)

                """)
        #expect(
            try runGoMain(
                #"""
                up := ToUpper
                p := Println
                p(up("dot"), HasPrefix("dot", "d"))
                Printf("%T\n", Join)
                """#,
                declarations: """
                    import (
                        . "fmt"
                        . "strings"
                    )
                    """)
                == "DOT true\nfunc([]string, string) string\n")
    }

    /// A library function has one type, and goes only where that type is
    /// wanted. Go names the operand too: `cannot use strings.ToUpper (value of
    /// type func(s string) string) as func(int) int value in variable declaration`.
    @Test func aValueOfAnotherTypeIsRefused() {
        #expect(
            goMainDiagnostic(
                """
                var f func(int) int = strings.ToUpper
                fmt.Println(f(1))
                """,
                imports: ["fmt", "strings"])
                == "cannot use strings.ToUpper (value of type func(string) string) as func(int) int value in variable declaration")
        #expect(
            goMainDiagnostic("fmt.Println(apply(strings.ToUpper))", imports: ["fmt", "strings"],
                declarations: "func apply(f func(int) string) string { return f(1) }")
                == "cannot use strings.ToUpper (value of type func(string) string) as func(int) string value in argument to apply")
        #expect(
            firstError(
                """
                f := strings.ToUpper
                fmt.Println(f(1))
                """,
                imports: ["fmt", "strings"])
                == "7:15: cannot use 1 (untyped int constant) as string value in argument to f")
        #expect(
            goMainDiagnostic(
                """
                var wg sync.WaitGroup
                var f func(int) int = wg.Add
                fmt.Println(f)
                """,
                imports: ["fmt", "sync"])
                == "cannot use wg.Add (value of type func(int)) as func(int) int value in variable declaration")
        #expect(
            firstError("fmt.Println(strings.ToUpper == strings.ToLower)", imports: ["fmt", "strings"])
                == "6:13: invalid operation: strings.ToUpper == strings.ToLower (func can only be compared to nil)")
        #expect(
            firstError(
                """
                f := strings.NoSuch
                fmt.Println(f)
                """,
                imports: ["fmt", "strings"])
                == "6:14: undefined: strings.NoSuch")
    }

    /// `errors.As` is compiled with the type of its target: it is no
    /// function a value could name, though Go has it as one. The functions
    /// of `net/http` are Go text of the library, and values like any
    /// function of a package.
    @Test func whatCannotBeAValueSaysSo() {
        #expect(
            goMainDiagnostic(
                """
                f := errors.As
                fmt.Println(f)
                """,
                imports: ["errors", "fmt"])
                == "errors.As is a function of the run-time library, which can only be called: wrap the call in a function literal to pass it")
        #expect(
            firstError(
                """
                f := http.HandleFunc
                fmt.Println(f)
                """,
                imports: ["fmt", "net/http"])
                == nil)
    }
}
