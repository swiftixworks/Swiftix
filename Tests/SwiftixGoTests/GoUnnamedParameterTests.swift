/// Receivers, parameters, and results without names: `func (T) m()`,
/// `func f(int, string)`, `func(_ int, _ string)`.
///
/// A list has names throughout or none at all, which Go decides after it
/// has read the list; the parser follows the same procedure and makes the
/// same two reports. A parameter without a name is one the blank
/// identifier names: nothing binds it, and any number may be so.
///
/// What each program prints is what Go 1.24.5 prints for it. An error pinned
/// with its place is at the place of the first one Go's compiler reports;
/// where the message is Go's too it was copied without change, and otherwise
/// it is this dialect's, which names a value by its type.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go unnamed receivers and parameters")
struct GoUnnamedParameterTests: GoTestHarness {

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

    /// `GoParameter` has a name; one the source leaves out is `_`. A result
    /// without a name stays without one, which is what tells a bare `return`.
    @Test func aParameterWithoutANameIsBlank() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: "package main\ntype T int\nfunc (T) m(int, ...string) (bool, error) { return false, nil }\n"
                    + "func f(a, b int, _ string) (n int, _ error) { return }\nfunc g(int, err error) {}\n"))
        let method = file.functions[0]

        #expect(method.receiver?.name == "_")
        #expect(method.parameters.map(\.name) == ["_", "_"])
        #expect(method.resultNames == [nil, nil])
        #expect(file.functions[1].parameters.map(\.name) == ["a", "b", "_"])
        #expect(file.functions[1].resultNames == ["n", "_"])
        // A name alone before a name with a type shares that type, as in Go.
        #expect(file.functions[2].parameters.map(\.name) == ["int", "err"])
    }

    /// `(T)`, `(*T)`, and `(_ T)`. The method is found through a value, a
    /// pointer, an interface, a method value, and a method expression, and
    /// `fmt` calls `Error` and `String` declared so.
    @Test func aReceiverNeedsNoName() throws {
        #expect(
            try runGoMain(
                #"""
                shapes := []shape{unit{}, square{3}, &square{4}}
                for _, s := range shapes {
                    fmt.Println(s.name(), s.area())
                }
                f := unit.area
                g := (*square).grow
                h := square{2}.name
                s := &square{5}
                g(s, 1)
                s.reset()
                fmt.Println(f(unit{}), h(), s.side)
                fmt.Printf("%T %T %T\n", f, g, h)
                fmt.Println(fail(), label{1})
                """#,
                declarations: """
                    type shape interface {
                        area() int
                        name() string
                    }
                    type unit struct{}
                    type square struct{ side int }
                    type failure struct{}
                    type label struct{ n int }

                    func (unit) area() int       { return 1 }
                    func (unit) name() string    { return "unit" }
                    func (s square) area() int   { return s.side * s.side }
                    func (square) name() string  { return "square" }
                    func (*square) grow(int)     {}
                    func (_ *square) reset()     {}
                    func (failure) Error() string { return "boom" }
                    func (label) String() string { return "label!" }

                    func fail() error { return failure{} }
                    """)
                == """
                unit 1
                square 9
                square 16
                1 square 5
                func(main.unit) int func(*main.square, int) func() string
                boom label!

                """)
    }

    /// Types alone, blank names, a variadic one, and results that the blank
    /// identifier names.
    @Test func parametersNeedNoNames() throws {
        #expect(
            try runGoMain(
                """
                a, b := named()
                n, e := mixed()
                fmt.Println(first(1, "a"), second(1, "b"), third(7, "c", true), both(1, 2))
                fmt.Println(a, b == "", n, e, depth(3, "x"))
                fmt.Println(variadic("a"), variadic("a", 1, 2), onlyVariadic(), onlyVariadic("x", "y"))
                xs := []int{1, 2}
                fmt.Println(variadic("s", xs...), kinds(nil, nil, nil, nil, nil, nil))
                """,
                declarations: """
                    func first(int, string) int               { return 1 }
                    func second(_ int, _ string) int          { return 2 }
                    func third(a int, _ string, _ bool) int   { return a }
                    func both(_, _ int) int                   { return 5 }
                    func named() (_ int, _ string)            { return }
                    func mixed() (n int, _ error)             { n = 4; return }
                    func variadic(_ string, _ ...int) int     { return 7 }
                    func onlyVariadic(...string) int          { return 8 }
                    func kinds(*int, []string, map[string]int, chan int, func(int) int, interface{}) int { return 9 }

                    func depth(n int, _ string) int {
                        if n == 0 {
                            return 0
                        }
                        return 1 + depth(n-1, "")
                    }
                    """)
                == "1 2 7 5\n0 true 4 <nil> 3\n7 7 8 8\n7 9\n")
    }

    /// A literal with unnamed parameters still captures the variables around
    /// it, in a loop, a goroutine, and a deferred call, and as a value of a
    /// package-level variable.
    @Test func aFunctionLiteralNeedsNoneEither() throws {
        #expect(
            try runGoMain(
                """
                sum := 0
                count := 0
                visit([]int{4, 5, 6}, func(_ int, x int) { sum += x })
                visit([]int{4, 5, 6}, func(int, int) { count++ })
                visit([]int{1}, func(_, _ int) { count += 10 })
                fmt.Println(sum, count)
                steps := []func(int) int{}
                for i := 0; i < 3; i++ {
                    steps = append(steps, func(int) int { return i })
                }
                for _, step := range steps {
                    fmt.Print(step(0), " ")
                }
                fmt.Println()
                defer func(string) { fmt.Println("deferred", sum) }("x")
                done := make(chan int)
                go func(_ int, c chan int) { c <- count }(0, done)
                fmt.Println(<-done, table["first"](1, 2), table["second"](1, 2), table["zero"](1, 2))
                var h handler = func(int, string) bool { return true }
                fmt.Println(run(h), run(func(n int, _ string) bool { return n > 5 }), h.describe())
                """,
                declarations: """
                    type handler func(int, string) bool

                    var table = map[string]func(int, int) int{
                        "first":  func(a, _ int) int { return a },
                        "second": func(_, b int) int { return b },
                        "zero":   func(int, int) int { return 0 },
                    }

                    func (handler) describe() string { return "handler" }

                    func run(h handler) bool { return h(1, "a") }

                    func visit(xs []int, f func(int, int)) {
                        for i, x := range xs {
                            f(i, x)
                        }
                    }
                    """)
                == "15 13\n0 1 2 \n13 1 2 0\ntrue false handler\ndeferred 15\n")
    }

    /// Go's two reports: a name no type follows is a missing type, at the
    /// `)`, and a type where a name must be is a missing name, where the type
    /// is. A function type and an interface method are held to the same.
    @Test func aListHasNamesThroughoutOrNone() {
        #expect(
            firstError("", declarations: "func f(a int, string) {}")
                == "3:21: syntax error: missing parameter type")
        #expect(
            firstError("", declarations: "func f(a int, b) {}")
                == "3:16: syntax error: missing parameter type")
        #expect(
            firstError("", declarations: "func f() (a int, string) { return 1, \"a\" }")
                == "3:24: syntax error: missing parameter type")
        #expect(
            firstError("", declarations: "func f(a int, []string) {}")
                == "3:15: syntax error: missing parameter name")
        #expect(
            firstError("", declarations: "func f(a int, ...string) {}")
                == "3:15: syntax error: missing parameter name")
        #expect(
            firstError(
                """
                f := func(a int, string) {}
                _ = f
                """)
                == "5:24: syntax error: missing parameter type")
        #expect(
            firstError(
                """
                var f func(a int, string)
                _ = f
                """)
                == "5:25: syntax error: missing parameter type")
        #expect(
            firstError("", declarations: """
                    type i interface {
                        m(a int, string)
                    }
                    """)
                == "4:20: syntax error: missing parameter type")
        #expect(
            firstError("", declarations: "func f(a, b) {}")
                == "3:8: undefined: a")
    }

    /// A variadic parameter is the last, a name is declared once, the blank
    /// identifier is no value, and a method has one receiver.
    @Test func whatIsWrongWithAListIsReportedAsGoReportsIt() {
        #expect(
            firstError("", declarations: "func f(...int, string) {}")
                == "3:8: can only use ... with final parameter in list")
        #expect(
            firstError("", declarations: "func f(a int, a string) {}")
                == "3:15: a redeclared in this block")
        #expect(
            firstError(
                """
                f := func(a int, a string) {}
                _ = f
                """)
                == "5:18: a redeclared in this block")
        #expect(
            firstError("", declarations: "func f(_ int, _ int) int { return _ }")
                == "3:35: cannot use _ as value or type")
        #expect(
            firstError("", declarations: """
                    type t struct{}

                    func (a, b t) m() {}
                    """)
                == "5:15: method has multiple receivers")
        #expect(
            firstError("", declarations: """
                    type t struct{}

                    func () m() {}
                    """)
                == "5:9: method has no receiver")
        #expect(
            firstError("", declarations: """
                    type t struct{}

                    func (x t, y t) m() {}
                    """)
                == "5:17: method has multiple receivers")
        #expect(
            firstError("", declarations: "func f(int) int")
                == "3:6: missing function body")
    }
}
