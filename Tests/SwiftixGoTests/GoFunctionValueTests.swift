/// Functions as values: function types, a function, a method, or a literal
/// where a value is wanted, and a call through what holds one.
///
/// What a literal captures is in `GoClosureTests`. What each program prints
/// is what Go 1.24.5 prints for it, and each error pinned with its place is
/// the first one its compiler reports, copied without change; a message
/// pinned alone is one this dialect words in its own way. How `gofmt` lays
/// function types and literals out is compared with Go's in
/// `GoGofmtConformanceTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go function values")
struct GoFunctionValueTests: GoTestHarness {

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

    /// `GoTypeExpression` has no case for a function type: it is an interface
    /// with one method whose name is no identifier.
    @Test func aFunctionTypeIsCarriedAsAnInterfaceNoSourceCanWrite() throws {
        let file = try GoParser.parse(
            GoSourceFile(
                path: "main.go",
                text: "package main\nvar f func(int, string) (bool, error)\nvar g func()\nvar i interface{ M() }\n"))
        let signature = try #require(file.globalDeclarations[0].explicitType?.functionSignature)

        #expect(signature.parameters.count == 2)
        #expect(signature.results.count == 2)
        #expect(file.globalDeclarations[1].explicitType?.functionSignature?.parameters.isEmpty == true)
        #expect(file.globalDeclarations[1].explicitType?.functionSignature?.results.isEmpty == true)
        // An interface a program writes is not one.
        #expect(file.globalDeclarations[2].explicitType?.functionSignature == nil)
        #expect(GoType.function(parameters: [.int, .string], results: []).description == "func(int, string)")
        #expect(
            GoType.function(parameters: [.slice(.int)], results: [.int, .bool]).description
                == "func([]int) (int, bool)")
    }

    /// It is passed, returned, stored in a variable, and called through one.
    /// `%T` prints its type the way Go writes it.
    @Test func aFunctionIsAValue() throws {
        #expect(
            try runGoMain(
                #"""
                var f op = add
                g := func(a, b int) int { return a - b }
                var h func(int, int) int = f
                fmt.Println(apply(add, 1, 2), f(3, 4), g(3, 4), apply(g, 5, 6), h(1, 1))
                fmt.Println(pick("add")(2, 5), pick("mul")(2, 5), op(g)(9, 1))
                fmt.Printf("%T %T %T\n", add, f, g)
                fmt.Printf("%T %T\n", pick, apply)
                """#,
                declarations: """
                    type op func(int, int) int

                    func add(a, b int) int { return a + b }

                    func apply(f func(int, int) int, a, b int) int { return f(a, b) }

                    func pick(name string) op {
                        if name == "add" {
                            return add
                        }
                        return func(a, b int) int { return a * b }
                    }
                    """)
                == """
                3 7 -1 -1 2
                7 10 8
                func(int, int) int main.op func(int, int) int
                func(string) main.op func(func(int, int) int, int, int) int

                """)
    }

    /// A field, an element, or what a receive gives is called like a
    /// variable.
    @Test func functionsAreStoredInStructsSlicesMapsAndChannels() throws {
        #expect(
            try runGoMain(
                """
                h := handler{name: "up", run: func(s string) string { return s + "!" }}
                steps := []func(int) int{
                    func(n int) int { return n + 1 },
                    double,
                }
                table := map[string]func(int) int{"double": double, "neg": func(n int) int { return -n }}
                n := 1
                for _, step := range steps {
                    n = step(n)
                }
                fmt.Println(h.run(h.name), n, steps[0](10), table["double"](4), table["neg"](4), len(table))
                jobs := make(chan func() int, 2)
                jobs <- func() int { return 7 }
                jobs <- func() int { return n }
                close(jobs)
                for job := range jobs {
                    fmt.Print(job(), " ")
                }
                fmt.Println()
                """,
                declarations: """
                    type handler struct {
                        name string
                        run  func(string) string
                    }

                    func double(n int) int { return n * 2 }
                    """)
                == "up! 4 11 8 -4 2\n7 4 \n")
    }

    /// A function is compared with `nil` and with nothing else; a call
    /// through `nil` is the panic of a nil pointer.
    @Test func theZeroValueIsNilAndCallingItPanics() throws {
        #expect(
            try runGoMain(
                """
                var none func()
                var table map[string]func(int) int
                fmt.Println(none == nil, nil != none, table["x"] == nil)
                none = func() {}
                fmt.Println(none == nil, none != nil)
                defer func() { fmt.Println("recovered:", recover()) }()
                var f func(int) int
                fmt.Println(f(1))
                """)
                == """
                true false true
                false true
                recovered: runtime error: invalid memory address or nil pointer dereference

                """)
        #expect(
            goMainDiagnostic(
                """
                f, g := func() {}, func() {}
                fmt.Println(f == g)
                """)
                == "invalid operation: func can only be compared to nil")
        #expect(
            firstError(
                """
                m := map[func()]int{}
                fmt.Println(len(m))
                """)
                == "5:14: invalid map key type func()")
        #expect(
            firstError(
                """
                var m map[string]map[[]func()]int
                fmt.Println(len(m))
                """)
                == "5:22: invalid map key type []func()")
    }

    /// `c.get` is a function that has `c` already: a value receiver is copied
    /// when the method is selected, a pointer receiver is shared.
    @Test func aMethodValueHasItsReceiver() throws {
        #expect(
            try runGoMain(
                #"""
                c := counter{n: 1}
                get := c.get
                c.n = 5
                p := &c
                inc, add := p.inc, c.add
                inc()
                inc()
                fmt.Println(get(), add(10), c.n, p.get())
                pair, sum := c.pair, p.sum
                n, s := pair()
                fmt.Println(n, s, sum(), sum(1, 2))
                fmt.Printf("%T %T %T %T\n", get, inc, pair, sum)
                """#,
                declarations: """
                    type counter struct{ n int }

                    func (c counter) get() int            { return c.n }
                    func (c counter) plus(a, b int) int   { return c.n + a + b }
                    func (c counter) pair() (int, string) { return c.n, "n" }
                    func (c *counter) inc()               { c.n++ }
                    func (c *counter) add(by int) int {
                        c.n += by
                        return c.n
                    }
                    func (c counter) sum(xs ...int) int {
                        t := c.n
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }
                    """)
                == """
                1 17 17 17
                17 n 17 20
                func() int func() func() (int, string) func(...int) int

                """)
    }

    /// `T.m` and `(*T).m` are the method as a function whose first argument
    /// is the receiver. `(*T).m` is one for a method of `T` as well.
    @Test func aMethodExpressionTakesItsReceiver() throws {
        #expect(
            try runGoMain(
                #"""
                get, inc, viaPointer := counter.get, (*counter).inc, (*counter).get
                c := counter{n: 3}
                inc(&c)
                inc(&c)
                fmt.Println(get(c), viaPointer(&c), counter.plus(c, 1, 2), (*counter).add(&c, 10), c.n)
                n, s := counter.pair(c)
                m, t := (*counter).pair(&c)
                fmt.Println(n, s, m, t, counter.sum(c), counter.sum(c, 1, 2), (*counter).sum(&c, 1))
                fmt.Printf("%T %T %T %T\n", get, inc, viaPointer, counter.sum)
                all := []func(counter) int{counter.get, func(c counter) int { return -c.n }}
                for _, f := range all {
                    fmt.Print(f(c), " ")
                }
                fmt.Println()
                """#,
                declarations: """
                    type counter struct{ n int }

                    func (c counter) get() int            { return c.n }
                    func (c counter) plus(a, b int) int   { return c.n + a + b }
                    func (c counter) pair() (int, string) { return c.n, "n" }
                    func (c *counter) inc()               { c.n++ }
                    func (c *counter) add(by int) int {
                        c.n += by
                        return c.n
                    }
                    func (c counter) sum(xs ...int) int {
                        t := c.n
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }
                    """)
                == "5 5 8 15 15\n15 n 15 n 15 18 16\nfunc(main.counter) int func(*main.counter) func(*main.counter) int func(main.counter, ...int) int\n15 -15 \n")
        #expect(
            firstError(
                """
                f := counter.inc
                f(nil)
                """,
                declarations: """
                    type counter struct{ n int }

                    func (c counter) get() int            { return c.n }
                    func (c counter) plus(a, b int) int   { return c.n + a + b }
                    func (c counter) pair() (int, string) { return c.n, "n" }
                    func (c *counter) inc()               { c.n++ }
                    func (c *counter) add(by int) int {
                        c.n += by
                        return c.n
                    }
                    func (c counter) sum(xs ...int) int {
                        t := c.n
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }
                    """)
                == "21:14: invalid method expression counter.inc (needs pointer receiver (*counter).inc)")
        #expect(
            firstError(
                """
                f := counter.nope
                f()
                """,
                declarations: """
                    type counter struct{ n int }

                    func (c counter) get() int            { return c.n }
                    func (c counter) plus(a, b int) int   { return c.n + a + b }
                    func (c counter) pair() (int, string) { return c.n, "n" }
                    func (c *counter) inc()               { c.n++ }
                    func (c *counter) add(by int) int {
                        c.n += by
                        return c.n
                    }
                    func (c counter) sum(xs ...int) int {
                        t := c.n
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }
                    """)
                == "21:14: counter.nope undefined (type counter has no field or method nope)")
        #expect(
            firstError(
                """
                f := (*counter).nope
                f()
                """,
                declarations: """
                    type counter struct{ n int }

                    func (c counter) get() int            { return c.n }
                    func (c counter) plus(a, b int) int   { return c.n + a + b }
                    func (c counter) pair() (int, string) { return c.n, "n" }
                    func (c *counter) inc()               { c.n++ }
                    func (c *counter) add(by int) int {
                        c.n += by
                        return c.n
                    }
                    func (c counter) sum(xs ...int) int {
                        t := c.n
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }
                    """)
                == "21:17: (*counter).nope undefined (type *counter has no field or method nope)")
        #expect(
            firstError(
                """
                f := counter.n
                f()
                """,
                declarations: """
                    type counter struct{ n int }

                    func (c counter) get() int            { return c.n }
                    func (c counter) plus(a, b int) int   { return c.n + a + b }
                    func (c counter) pair() (int, string) { return c.n, "n" }
                    func (c *counter) inc()               { c.n++ }
                    func (c *counter) add(by int) int {
                        c.n += by
                        return c.n
                    }
                    func (c counter) sum(xs ...int) int {
                        t := c.n
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }
                    """)
                == "21:14: counter.n undefined (type counter has no method n)")
        #expect(
            goMainDiagnostic("fmt.Println(counter.get(1))", declarations: """
                    type counter struct{ n int }

                    func (c counter) get() int            { return c.n }
                    func (c counter) plus(a, b int) int   { return c.n + a + b }
                    func (c counter) pair() (int, string) { return c.n, "n" }
                    func (c *counter) inc()               { c.n++ }
                    func (c *counter) add(by int) int {
                        c.n += by
                        return c.n
                    }
                    func (c counter) sum(xs ...int) int {
                        t := c.n
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }
                    """)
                == "cannot use int as counter value in argument to counter.get")
        #expect(
            goMainDiagnostic("fmt.Println((*counter).get(1))", declarations: """
                    type counter struct{ n int }

                    func (c counter) get() int            { return c.n }
                    func (c counter) plus(a, b int) int   { return c.n + a + b }
                    func (c counter) pair() (int, string) { return c.n, "n" }
                    func (c *counter) inc()               { c.n++ }
                    func (c *counter) add(by int) int {
                        c.n += by
                        return c.n
                    }
                    func (c counter) sum(xs ...int) int {
                        t := c.n
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }
                    """)
                == "cannot use int as *counter value in argument to (*counter).get")
        #expect(
            goMainDiagnostic("fmt.Println(counter.get())", declarations: """
                    type counter struct{ n int }

                    func (c counter) get() int            { return c.n }
                    func (c counter) plus(a, b int) int   { return c.n + a + b }
                    func (c counter) pair() (int, string) { return c.n, "n" }
                    func (c *counter) inc()               { c.n++ }
                    func (c *counter) add(by int) int {
                        c.n += by
                        return c.n
                    }
                    func (c counter) sum(xs ...int) int {
                        t := c.n
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }
                    """)
                == "not enough arguments in call to counter.get")
    }

    /// `s.area` with `s` an interface is the method of what `s` holds when it
    /// is selected, kept with that value; selecting one of an interface that
    /// holds nothing panics there, called or not.
    @Test func aMethodOfAnInterfaceValueIsAFunction() throws {
        #expect(
            try runGoMain(
                #"""
                var s shape = rect{2, 3}
                area, scaled := s.area, s.scaled
                s = &square{4}
                other := s.area
                fmt.Println(area(), other(), scaled(2).area(), total(area, other, s.scaled(2).area))
                text, n := s.describe("a ", "x")
                describe := scaled(3).describe
                more, m := describe("b ", "!", "?")
                fmt.Println(text, n, more, m)
                fmt.Printf("%T %T %T\n", area, scaled, describe)

                var err error = errors.New("broken")
                message := err.Error
                err = fmt.Errorf("wrapped: %w", err)
                fmt.Println(message(), err.Error(), len(message()))

                defer func() { fmt.Println("recovered:", recover()) }()
                var none shape
                unreached := none.area
                fmt.Println("unreached", unreached == nil)
                """#,
                imports: ["fmt", "errors", "strings"],
                declarations: """
                    type shape interface {
                        area() int
                        scaled(by int) shape
                        describe(prefix string, parts ...string) (string, int)
                    }

                    type rect struct{ w, h int }

                    func (r rect) area() int           { return r.w * r.h }
                    func (r rect) scaled(by int) shape { return rect{r.w * by, r.h * by} }
                    func (r rect) describe(prefix string, parts ...string) (string, int) {
                        return prefix + "rect" + strings.Join(parts, ""), len(parts)
                    }

                    type square struct{ side int }

                    func (s *square) area() int           { return s.side * s.side }
                    func (s *square) scaled(by int) shape { return &square{s.side * by} }
                    func (s *square) describe(prefix string, parts ...string) (string, int) {
                        return prefix + "square", -len(parts)
                    }

                    func total(areas ...func() int) int {
                        sum := 0
                        for _, area := range areas {
                            sum += area()
                        }
                        return sum
                    }
                    """)
                == """
                6 16 24 86
                a square -1 b rect!? 2
                func() int func(int) main.shape func(string, ...string) (string, int)
                broken wrapped: broken 6
                recovered: runtime error: invalid memory address or nil pointer dereference

                """)
        #expect(
            goMainDiagnostic(
                """
                var s shape
                f := s.volume
                f()
                """,
                declarations: "type shape interface{ area() int }")
                == "shape has no field or method volume")
    }

    /// Which is how a function becomes a value of an interface: the adapter
    /// every middleware chain is made of.
    @Test func aNamedFunctionTypeHasMethods() throws {
        #expect(
            try runGoMain(
                #"""
                var h handler = handlerFunc(func(s string) string { return s + "!" })
                logged := []string{}
                chain := wrap(wrap(h, "a"), "b")
                trace := handlerFunc(func(s string) string {
                    logged = append(logged, s)
                    return chain.serve(s)
                })
                fmt.Println(h.serve("x"), chain.serve("y"), trace.serve("z"), logged)
                fmt.Printf("%T %T\n", h, trace)
                var plain func(string) string = trace
                fmt.Println(plain("w"), handlerFunc(plain).serve("v"), len(logged))
                """#,
                declarations: """
                    type handler interface{ serve(string) string }

                    type handlerFunc func(string) string

                    func (f handlerFunc) serve(s string) string { return f(s) }

                    func wrap(next handler, name string) handler {
                        return handlerFunc(func(s string) string { return name + "(" + next.serve(s) + ")" })
                    }
                    """)
                == """
                x! b(a(y!)) b(a(z!)) [z]
                main.handlerFunc main.handlerFunc
                b(a(w!)) b(a(v!)) 3

                """)
    }

    /// Its last parameter takes any number of arguments, or a slice with
    /// `...`, through a variable as it does by name.
    @Test func aVariadicFunctionIsAValue() throws {
        #expect(
            try runGoMain(
                #"""
                f := sum
                g := func(prefix string, xs ...int) string { return prefix + fmt.Sprint(len(xs)) }
                s := []int{4, 5}
                fmt.Println(f(), f(1, 2, 3), f(s...), g("n"), g("n", 1, 2), g("n", s...))
                fmt.Printf("%T %T\n", f, g)
                """#,
                declarations: """
                    func sum(xs ...int) int {
                        t := 0
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }
                    """)
                == "0 6 9 n0 n2 n2\nfunc(...int) int func(string, ...int) string\n")
    }

    /// A call through a value is one of several results where a call by
    /// name is.
    @Test func aFunctionValueGivesSeveralResults() throws {
        #expect(
            try runGoMain(
                """
                divide := func(a, b int) (int, error) {
                    if b == 0 {
                        return 0, errors.New("division by zero")
                    }
                    return a / b, nil
                }
                q, err := divide(7, 2)
                fmt.Println(q, err)
                _, err = divide(1, 0)
                fmt.Println(err)
                both := func() (int, error) { return divide(9, 3) }
                q, err = both()
                fmt.Println(q, err)
                if q, err := divide(8, 0); err != nil {
                    fmt.Println("failed:", q, err)
                }
                """,
                imports: ["fmt", "errors"])
                == "3 <nil>\ndivision by zero\n3 <nil>\nfailed: 0 division by zero\n")
    }

    /// An `any` holds a function, and a type assertion gives it back when the
    /// signature is the one asserted.
    @Test func aFunctionInAnInterfaceValueIsAssertedBack() throws {
        #expect(
            try runGoMain(
                #"""
                var x any = func(n int) int { return n + 1 }
                if f, ok := x.(func(int) int); ok {
                    fmt.Println(f(1))
                }
                _, ok := x.(func())
                fmt.Printf("%T %v\n", x, ok)
                values := []any{1, "s", func() string { return "called" }}
                for _, v := range values {
                    if f, ok := v.(func() string); ok {
                        fmt.Println(f())
                    }
                }
                """#)
                == "2\nfunc(int) int false\ncalled\n")
    }

    /// `go f(x)` and `defer f(x)` take a value as they take a name: the
    /// function and its arguments are read when the statement runs.
    @Test func goAndDeferCallThroughAValue() throws {
        #expect(
            try runGoMain(
                """
                var wg sync.WaitGroup
                results := make(chan int, 3)
                work := func(n int) {
                    defer wg.Done()
                    results <- n * n
                }
                for i := 1; i <= 3; i++ {
                    wg.Add(1)
                    go work(i)
                }
                wg.Wait()
                close(results)
                total := 0
                for r := range results {
                    total += r
                }
                fmt.Println(total)
                report := func(label string, n int) { fmt.Println(label, n) }
                defer report("deferred first, runs last:", total)
                report = func(label string, n int) { fmt.Println("replaced", label, n) }
                total = 0
                defer report("deferred second:", total)
                """,
                imports: ["fmt", "sync"])
                == "14\nreplaced deferred second: 0\ndeferred first, runs last: 14\n")
    }

    /// A literal has no name; the variable it is assigned to is how it
    /// recurses.
    @Test func aFunctionCallsItselfThroughAVariable() throws {
        #expect(
            try runGoMain(
                """
                var fib func(int) int
                fib = func(n int) int {
                    if n < 2 {
                        return n
                    }
                    return fib(n-1) + fib(n-2)
                }
                var even, odd func(int) bool
                even = func(n int) bool { return n == 0 || odd(n-1) }
                odd = func(n int) bool { return n != 0 && even(n-1) }
                fmt.Println(fib(15), even(10), odd(7), even(3))
                """)
                == "610 true true false\n")
    }

    /// A function that defers gives what its results hold when it is done,
    /// which a deferred call may have changed, a panic or not.
    @Test func deferredCallsSeeAndChangeNamedResults() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println(clamp(5), clamp(-5))
                value, err := safe(func() int { return 7 })
                fmt.Println(value, err)
                value, err = safe(func() int { panic("boom") })
                fmt.Println(value, err)
                n, s := unnamed(func() { panic("lost") })
                fmt.Println(n, s == "")
                """,
                declarations: """
                    func clamp(n int) (result int) {
                        defer func() {
                            if result < 0 {
                                result = 0
                            }
                        }()
                        return n * 2
                    }

                    func safe(f func() int) (value int, err error) {
                        defer func() {
                            if r := recover(); r != nil {
                                value, err = -1, fmt.Errorf("recovered: %v", r)
                            }
                        }()
                        return f(), nil
                    }

                    func unnamed(f func()) (int, string) {
                        defer func() { recover() }()
                        f()
                        return 1, "unreached"
                    }
                    """)
                == "10 0\n7 <nil>\n-1 recovered: boom\n0 true\n")
    }

    /// What is called, and with what, is checked against the type of the
    /// value.
    @Test func aValueThatIsNoFunctionIsNotCalled() {
        #expect(
            firstError(
                """
                x := 1
                x()
                """)
                == "6:1: invalid operation: cannot call non-function x (variable of type int)")
        #expect(
            goMainDiagnostic(
                """
                f := func(a, b int) int { return a + b }
                fmt.Println(f(1))
                """)
                == "not enough arguments in call to f")
        #expect(
            goMainDiagnostic(
                """
                f := func(a int) int { return a }
                fmt.Println(f(1, 2))
                """)
                == "too many arguments in call to f")
        #expect(
            goMainDiagnostic(
                """
                f := func(a int) int { return a }
                fmt.Println(f("s"))
                """)
                == "cannot use string as int value in argument to f")
        #expect(
            goMainDiagnostic(
                """
                var f func(int) int = add
                fmt.Println(f(1))
                """,
                declarations: "func add(a, b int) int { return a + b }")
                == "cannot use func(int, int) int as func(int) int value")
        #expect(
            goMainDiagnostic(
                """
                f := func() int { return 1 }
                f = 2
                fmt.Println(f())
                """)
                == "cannot use int as func() int value")
        #expect(
            firstError(
                """
                f := func() int {}
                fmt.Println(f())
                """)
                == "5:18: missing return")
        #expect(
            goMainDiagnostic(
                """
                f := func() int { return "s" }
                fmt.Println(f())
                """)
                == "cannot use string as int value in return statement")
        #expect(
            goMainDiagnostic(
                """
                f := fmt.Sprint
                fmt.Println(f(1))
                """)
                == "fmt.Sprint is a function of the run-time library, which can only be called: wrap the call in a function literal to pass it")
        #expect(
            goMainDiagnostic(
                """
                f := fmt.Println
                f("x")
                """)
                == "fmt.Println is a function of the run-time library, which can only be called: wrap the call in a function literal to pass it")
    }

    /// The handler is a function of the two parameters Go gives it, by name
    /// or as a literal.
    @Test func httpHandleFuncTakesAFunction() throws {
        #expect(
            try runGoMain(
                """
                hits := 0
                http.HandleFunc("/", index)
                http.HandleFunc("/hit", func(w http.ResponseWriter, r *http.Request) { hits++ })
                fmt.Println("registered", hits)
                """,
                imports: ["fmt", "net/http"],
                declarations: "func index(w http.ResponseWriter, r *http.Request) {}")
                == "registered 0\n")
        #expect(
            goMainDiagnostic("http.HandleFunc(\"/\", 42)", imports: ["fmt", "net/http"])
                == "cannot use int as func(http.ResponseWriter, *http.Request) value in argument to http.HandleFunc")
        #expect(
            goMainDiagnostic("http.HandleFunc(\"/\", func() {})", imports: ["fmt", "net/http"])
                == "cannot use func() as func(http.ResponseWriter, *http.Request) value in argument to http.HandleFunc")
    }
}
