/// A call of several results: as the arguments of another call, `f(g())`,
/// where Go passes every result on, and everywhere else, where Go wants one
/// value and refuses the call.
///
/// What each program prints is what Go 1.24.5 prints for it. An error pinned
/// by `firstError` stands where Go reports its own first error for the
/// program; its words are Go's too wherever Go names the operand by nothing
/// but the call, and this dialect's where Go quotes the operand and its type
/// or lists what a call has and wants.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go call results as arguments")
struct GoForwardedResultTests: GoTestHarness {

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

    /// What the module `example/m` made of `files` prints: each file belongs
    /// to the package its directory names.
    private func runModule(_ files: [(path: String, text: String)]) throws -> String {
        var sources: [String: [GoSourceFile]] = [:]
        for file in files {
            let directory = file.path.split(separator: "/").dropLast().joined(separator: "/")
            sources[directory.isEmpty ? "example/m" : "example/m/" + directory, default: []]
                .append(GoSourceFile(path: "/m/" + file.path, text: file.text))
        }
        let executable = try GoCompiler.compile(
            packages: sources.keys.sorted().map {
                GoPackageSource(importPath: $0, sources: sources[$0] ?? [])
            },
            root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        return output
    }

    /// Where `g()` is the only argument of `f(g())` and `g` has several
    /// results, they are the arguments of `f`, in order: in a statement, an
    /// operand, a declaration of one name or of several, an assignment, and a
    /// `return`, and through as many calls as are written inside each other.
    @Test func theResultsOfACallAreTheArgumentsOfAnother() throws {
        #expect(
            try runGoMain(
                """
                take(pair())
                fmt.Println(pair())
                n := size(pair())
                s, m := swap(pair())
                fmt.Println(n, s, m, size(pair())+1, []int{size(pair())})
                var t, k = swap(pair())
                s, m = swap(back(swap(pair())))
                fmt.Println(t, k, s, m)
                fmt.Println(back(swap(pair())))
                fmt.Println(forward())
                fmt.Println(one())
                if size(pair()) > 5 {
                    fmt.Println("large")
                }
                switch size(pair()) {
                case 12:
                    fmt.Println("twelve")
                }
                for i := size(pair()); i < 13; i++ {
                    fmt.Println("once", i)
                }
                """,
                declarations: """
                    func pair() (int, string) { return 7, "seven" }

                    func take(n int, s string)               { fmt.Println("take", n, s) }
                    func size(n int, s string) int           { return n + len(s) }
                    func swap(n int, s string) (string, int) { return s, n }
                    func back(s string, n int) (int, string) { return n, s }
                    func forward() (int, string)             { return back(swap(pair())) }
                    func one() int                           { return size(back(swap(pair()))) }
                    """)
                == """
                take 7 seven
                7 seven
                12 seven 7 13 [12]
                seven 7 seven 7
                7 seven
                7 seven
                12
                large
                twelve
                once 12

                """)
        #expect(
            try runGoMain("fmt.Println(total, text, first, second)", declarations: """
                    func pair() (int, string) { return 7, "seven" }

                    func size(n int, s string) int           { return n + len(s) }
                    func swap(n int, s string) (string, int) { return s, n }

                    var total = size(pair())
                    var text = fmt.Sprint(pair())
                    var first = size(swap2(swap(pair())))
                    var second = len(fmt.Sprintln(swap(pair())))

                    func swap2(s string, n int) (int, string) { return n, s }
                    """)
                == "12 7seven 12 8\n")
    }

    /// The results go from where the inner call left them to the call that
    /// takes them: no variable is made for them, and no instruction is new.
    @Test func forwardingCostsTheTwoCalls() throws {
        let executable = try GoCompiler.compile(sources: [
            GoSourceFile(
                path: "main.go",
                text: goMainSource(
                    "take(pair())",
                    declarations: "func pair() (int, string) { return 7, \"seven\" }\nfunc take(n int, s string) {}"))
        ])
        let main = try #require(executable.functions.first { $0.name == "main" })

        #expect(main.localCount == 2)
        #expect(main.instructions == [
            .call("pair", argumentCount: 0), .store(1), .store(0),
            .load(0), .load(1), .call("take", argumentCount: 2), .return,
        ])
    }

    /// A function, a method with a value or a pointer receiver, a method of an
    /// interface value, a method value and a method expression, a function in a
    /// variable, a field, a slice, an array, or a map, what a call returns, and a
    /// literal called where it is written.
    @Test func everyKindOfCalleeTakesThem() throws {
        #expect(
            try runGoMain(
                """
                b := box{1}
                p := &box{10}
                var i shower = b
                fmt.Println(show(pair()))
                fmt.Println(b.show(pair()))
                fmt.Println(p.show(pair()))
                fmt.Println(b.grow(pair()), b.n)
                fmt.Println(p.grow(pair()), p.n)
                fmt.Println(i.show(pair()))
                fmt.Println(box{4}.show(pair()))
                fmt.Println((&box{5}).grow(pair()))

                bound := b.show
                grows := p.grow
                through := i.show
                fmt.Println(bound(pair()))
                fmt.Println(grows(pair()), p.n)
                fmt.Println(through(pair()))
                fmt.Println(box.show(func() (box, int, string) { return box{6}, 1, "x" }()))
                fmt.Println((*box).grow(func() (*box, int, string) { return p, 1, "x" }()))
                """,
                declarations: """
                    type box struct{ n int }

                    func (b box) show(a int, s string) string  { return fmt.Sprint("show ", b.n, " ", a, " ", s) }
                    func (b *box) grow(a int, s string) string { b.n += a; return fmt.Sprint("grow ", b.n, " ", s) }
                    func (b box) rest(label string, xs ...int) string {
                        return fmt.Sprint(label, " ", b.n, " ", xs, " ", len(xs))
                    }

                    type shower interface {
                        show(a int, s string) string
                        rest(label string, xs ...int) string
                    }

                    func pair() (int, string)         { return 7, "seven" }
                    func lead() (string, int, int)    { return "lead", 1, 2 }
                    func only() (string, int)         { return "only", 1 }
                    func show(a int, s string) string { return fmt.Sprint("func ", a, " ", s) }
                    """)
                == """
                func 7 seven
                show 1 7 seven
                show 10 7 seven
                grow 8 seven 8
                grow 17 seven 17
                show 1 7 seven
                show 4 7 seven
                grow 12 seven
                show 8 7 seven
                grow 24 seven 24
                show 1 7 seven
                show 6 1 x
                grow 25 x

                """)
        #expect(
            try runGoMain(
                """
                h := holder{run: show, list: []func(int, string) string{show}, named: map[string]func(int, string) string{"k": show}}
                fmt.Println(h.run(pair()))
                fmt.Println(h.list[0](pair()))
                fmt.Println(h.named["k"](pair()))
                fmt.Println((&h).run(pair()))
                table := [2]func(int, string) string{show, show}
                fmt.Println(table[1](pair()))
                var f func(int, string) string = show
                fmt.Println(f(pair()))
                fmt.Println(pick()(pair()))
                fmt.Println(func(a int, s string) string { return fmt.Sprint("literal ", a, " ", s) }(pair()))
                """,
                declarations: """
                    type box struct{ n int }

                    func (b box) show(a int, s string) string  { return fmt.Sprint("show ", b.n, " ", a, " ", s) }
                    func (b *box) grow(a int, s string) string { b.n += a; return fmt.Sprint("grow ", b.n, " ", s) }
                    func (b box) rest(label string, xs ...int) string {
                        return fmt.Sprint(label, " ", b.n, " ", xs, " ", len(xs))
                    }

                    type shower interface {
                        show(a int, s string) string
                        rest(label string, xs ...int) string
                    }

                    func pair() (int, string)         { return 7, "seven" }
                    func lead() (string, int, int)    { return "lead", 1, 2 }
                    func only() (string, int)         { return "only", 1 }
                    func show(a int, s string) string { return fmt.Sprint("func ", a, " ", s) }

                    type holder struct {
                        run   func(int, string) string
                        list  []func(int, string) string
                        named map[string]func(int, string) string
                    }

                    func pick() func(int, string) string { return show }
                    """)
                == """
                func 7 seven
                func 7 seven
                func 7 seven
                func 7 seven
                func 7 seven
                func 7 seven
                func 7 seven
                literal 7 seven

                """)
        #expect(
            try runGoMain(
                """
                b := box{2}
                var i shower = box{3}
                list := []func() (int, string){pair}
                named := map[string]func() (int, string){"k": pair}
                bound := b.both
                through := i.show
                fmt.Println(show(b.both()), show(list[0]()), show(named["k"]()), show(bound()))
                fmt.Println(show(source()()), show(box.both(b)), show((&b).both()), show(box{8}.both()))
                fmt.Println(show(func() (int, string) { return 9, "literal" }()), through(b.both()))
                """,
                declarations: """
                    type box struct{ n int }

                    func (b box) show(a int, s string) string  { return fmt.Sprint("show ", b.n, " ", a, " ", s) }
                    func (b *box) grow(a int, s string) string { b.n += a; return fmt.Sprint("grow ", b.n, " ", s) }
                    func (b box) rest(label string, xs ...int) string {
                        return fmt.Sprint(label, " ", b.n, " ", xs, " ", len(xs))
                    }

                    type shower interface {
                        show(a int, s string) string
                        rest(label string, xs ...int) string
                    }

                    func pair() (int, string)         { return 7, "seven" }
                    func lead() (string, int, int)    { return "lead", 1, 2 }
                    func only() (string, int)         { return "only", 1 }
                    func show(a int, s string) string { return fmt.Sprint("func ", a, " ", s) }

                    func (b box) both() (int, string) { return b.n, "method" }

                    func source() func() (int, string) { return pair }
                    """)
                == """
                func 2 method func 7 seven func 7 seven func 2 method
                func 7 seven func 2 method func 2 method func 8 method
                func 9 literal show 3 2 method

                """)
    }

    /// The results fill the fixed parameters and then the variadic one, as
    /// arguments written out would: all of them, some, or none.
    @Test func aVariadicParameterTakesTheRest() throws {
        #expect(
            try runGoMain(
                """
                b := box{3}
                var i shower = b
                fmt.Println(sum(two()), sum(three()))
                fmt.Println(join(lead()))
                fmt.Println(join(only()))
                fmt.Println(b.rest(lead()))
                fmt.Println(b.rest(only()))
                fmt.Println(i.rest(lead()))
                add, rest, bound := sum, join, b.rest
                fmt.Println(add(three()), rest(lead()), bound(lead()))
                fmt.Println(sum(spread(three())))
                fmt.Println(any3(mixed()))
                """,
                declarations: """
                    type box struct{ n int }

                    func (b box) show(a int, s string) string  { return fmt.Sprint("show ", b.n, " ", a, " ", s) }
                    func (b *box) grow(a int, s string) string { b.n += a; return fmt.Sprint("grow ", b.n, " ", s) }
                    func (b box) rest(label string, xs ...int) string {
                        return fmt.Sprint(label, " ", b.n, " ", xs, " ", len(xs))
                    }

                    type shower interface {
                        show(a int, s string) string
                        rest(label string, xs ...int) string
                    }

                    func pair() (int, string)         { return 7, "seven" }
                    func lead() (string, int, int)    { return "lead", 1, 2 }
                    func only() (string, int)         { return "only", 1 }
                    func show(a int, s string) string { return fmt.Sprint("func ", a, " ", s) }

                    func two() (int, int)        { return 3, 4 }
                    func three() (int, int, int) { return 1, 2, 3 }

                    func sum(xs ...int) int {
                        t := 0
                        for _, x := range xs {
                            t += x
                        }
                        return t
                    }

                    func join(label string, xs ...int) string { return fmt.Sprint(label, xs) }

                    func spread(xs ...int) (int, int) { return len(xs), sum(xs...) }

                    func mixed() (int, string, []int) { return 1, "a", []int{2} }

                    func any3(xs ...interface{}) string { return fmt.Sprintf("%d %T %T %T", len(xs), xs[0], xs[1], xs[2]) }
                    """)
                == """
                7 6
                lead[1 2]
                only[1]
                lead 3 [1 2] 2
                only 3 [1] 1
                lead 3 [1 2] 2
                6 lead[1 2] lead 3 [1 2] 2
                9
                3 int string []int

                """)
    }

    /// `fmt.Printf(format())` is legal where `format` returns the format and
    /// its operands, and every printer formats a result by the type it has.
    @Test func thePrintersOfTheLibraryTakeThem() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Println(mixed())
                fmt.Print(mixed())
                fmt.Println()
                fmt.Printf(format())
                fmt.Print(fmt.Sprint(mixed()), "\n")
                fmt.Print(fmt.Sprintln(mixed()))
                fmt.Print(fmt.Sprintf(format()))
                fmt.Println(fmt.Errorf(failure()))
                fmt.Printf("%v\n", fmt.Errorf(format()) == nil)
                fmt.Println(fmt.Sprintf(types()))
                fmt.Println(fmt.Sprint(count()))
                fmt.Println(fmt.Println("inner"))
                fmt.Println(fmt.Print("inner\n"))
                fmt.Println(fmt.Printf("%d\n", 5))
                """#,
                declarations: #"""
                    type code int

                    type point struct{ x, y int }

                    func (p point) String() string { return fmt.Sprint("(", p.x, ",", p.y, ")") }

                    type failed struct{ why string }

                    func (f *failed) Error() string { return "failed: " + f.why }

                    func mixed() (point, *point, code, []int, map[string]int, byte, bool, error) {
                        return point{1, 2}, &point{3, 4}, 5, []int{6}, map[string]int{"k": 7}, 'x', true, &failed{"so"}
                    }

                    func format() (string, string, int) { return "%s is %d\n", "answer", 42 }
                    func failure() (string, error)      { return "wrapped: %w", &failed{"inner"} }
                    func types() (string, code, point, *failed, interface{}) {
                        return "%T %T %T %T", 1, point{}, nil, []string{}
                    }
                    func count() (int, error) { return 3, nil }
                    """#)
                == """
                (1,2) (3,4) 5 [6] map[k:7] 120 true failed: so
                (1,2) (3,4) 5 [6] map[k:7] 120 true failed: so
                answer is 42
                (1,2) (3,4) 5 [6] map[k:7] 120 true failed: so
                (1,2) (3,4) 5 [6] map[k:7] 120 true failed: so
                answer is 42
                wrapped: failed: inner
                false
                main.code main.point *main.failed []string
                3 <nil>
                inner
                6 <nil>
                inner
                6 <nil>
                5
                2 <nil>

                """)
        #expect(
            try runGoMain(
                #"""
                fmt.Fprint(out())
                fmt.Fprintln(out())
                fmt.Fprintf(formatted())
                n, err := fmt.Fprintln(out())
                fmt.Println(n, err)
                fmt.Println(os.Stdout.WriteString("written\n"))
                """#,
                imports: ["fmt", "os"],
                declarations: #"""
                    func out() (*os.File, string, int)             { return os.Stdout, "to a file", 1 }
                    func formatted() (*os.File, string, int, bool) { return os.Stdout, "%d %v\n", 2, true }
                    """#)
                == "to a file1to a file 1\n2 true\nto a file 1\n12 <nil>\nwritten\n8 <nil>\n")
    }

    /// A function of the library checks the results against its parameters
    /// like any other, and so do the builtins that take ordinary arguments:
    /// `append`, `copy`, and `delete`.
    @Test func libraryFunctionsAndBuiltinsTakeThem() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println(strings.Repeat(times()), strings.Contains(parts()), strings.Index(parts()))
                fmt.Println(strings.Join(joined()), strings.TrimPrefix(parts()), strings.Split(parts()))
                fmt.Println(strings.HasPrefix(parts()), strings.HasSuffix(parts()), strings.Count(parts()))
                fmt.Println(strconv.Atoi("12"))
                fmt.Println(strconv.Atoi("x"))
                fmt.Println(errors.Is(chain()))
                var target *missing
                fmt.Println(errors.As(wrapped(&target)), target.name)
                """,
                imports: ["errors", "fmt", "strconv", "strings"],
                declarations: """
                    type missing struct{ name string }

                    func (m *missing) Error() string { return m.name + " is missing" }

                    func times() (string, int)       { return "ab", 3 }
                    func parts() (string, string)    { return "prefix-body", "prefix-" }
                    func joined() ([]string, string) { return []string{"a", "b"}, "+" }

                    func chain() (error, error) {
                        inner := errors.New("inner")
                        return fmt.Errorf("outer: %w", inner), inner
                    }

                    func wrapped(target **missing) (error, **missing) {
                        return fmt.Errorf("lookup: %w", &missing{"key"}), target
                    }
                    """)
                == """
                ababab true 0
                a+b body [ body]
                true false 1
                12 <nil>
                0 strconv.Atoi: parsing "x": invalid syntax
                true
                true key

                """)
        #expect(
            try runGoMain(
                #"""
                list := append(grown())
                fmt.Println(list, len(list), append(grown()))
                a, b := halves()
                fmt.Println(copy(halves()), a, b)
                delete(entry())
                fmt.Println(table)
                boxed := append(anything())
                fmt.Printf("%d %T %T\n", len(boxed), boxed[0], boxed[1])
                """#,
                declarations: """
                    type code int

                    var table = map[string]int{"a": 1, "b": 2}

                    var buffer = []int{0, 0, 0}

                    func grown() ([]int, int, int)                { return []int{1}, 2, 3 }
                    func halves() ([]int, []int)                  { return buffer, []int{9, 8} }
                    func entry() (map[string]int, string)         { return table, "a" }
                    func anything() ([]interface{}, code, []byte) { return nil, 4, []byte("x") }
                    """)
                == "[1 2 3] 3 [1 2 3]\n2 [9 8 0] [9 8]\nmap[b:2]\n2 main.code []uint8\n")
    }

    /// A result is a value of the type its function gave it: converted to an
    /// interface it keeps that type, and it is no constant that could become
    /// another integer type.
    @Test func aResultKeepsItsTypeAsAnArgument() throws {
        #expect(
            try runGoMain(
                """
                describe(values())
                many(values())
                check(found())
                check(lost())
                bytes(narrow())
                fmt.Println(send(ready()), put(keyed()), bump(pointed()), apply(doubled()))
                """,
                declarations: #"""
                    type code int

                    type point struct{ x, y int }

                    type failed struct{ why string }

                    func (f *failed) Error() string { return "failed: " + f.why }

                    func values() (code, point, *point, []string, byte, interface{}) {
                        return 4, point{1, 2}, &point{3, 4}, []string{"s"}, 'b', point{5, 6}
                    }

                    func describe(a, b, c, d, e, f interface{}) {
                        fmt.Printf("%T %T %T %T %T %T\n", a, b, c, d, e, f)
                        fmt.Println(a, b, c, d, e, f)
                    }

                    func many(xs ...interface{}) { fmt.Printf("%d %T %v\n", len(xs), xs[0], xs[len(xs)-1]) }

                    func found() (int, error) { return 1, nil }
                    func lost() (int, error)  { return 0, &failed{"lost"} }

                    func check(n interface{}, err error) { fmt.Printf("%T %v %T %v %v\n", n, n, err, err, err == nil) }

                    func narrow() (byte, code) { return 200, 300 }

                    func bytes(b byte, c code) { fmt.Println(b+100, c+1) }

                    func ready() (chan int, int)                    { return make(chan int, 1), 5 }
                    func send(c chan int, v int) int                { c <- v; return <-c }
                    func keyed() (map[string]int, string, int)      { return map[string]int{}, "k", 9 }
                    func put(m map[string]int, k string, v int) int { m[k] = v; return len(m) + m[k] }
                    func pointed() (*int, int)                      { n := 1; return &n, 41 }
                    func bump(p *int, by int) int                   { *p += by; return *p }
                    func doubled() (func(int) int, int)             { return func(x int) int { return x * 2 }, 21 }
                    func apply(f func(int) int, v int) int          { return f(v) }
                    """#)
                == """
                main.code main.point *main.point []string uint8 main.point
                4 {1 2} &{3 4} [s] 98 {5 6}
                6 main.code {5 6}
                int 1 <nil> <nil> true
                int 0 *main.failed failed: lost false
                44 301
                5 10 42 42

                """)
        #expect(
            firstError("bytes(ints())", declarations: """
                    func ints() (int, int)    { return 1, 2 }
                    func bytes(b byte, n int) {}
                    """)
                == "6:7: cannot use int as byte value in argument to bytes")
        #expect(
            firstError("plain(named())", declarations: """
                    type code int

                    func named() (code, string) { return 1, "a" }
                    func plain(n int, s string) {}
                    """)
                == "8:7: cannot use code as int value in argument to plain")
    }

    /// Go makes the calls of an expression in the order the source has them:
    /// the calls a callee is made of, then the call whose results it takes. What
    /// else the callee reads, it reads when it is called: the variable that holds
    /// the function, a receiver, an element, each as the inner call left it.
    @Test func theInnerCallRunsOnceAndWhereGoRunsIt() throws {
        #expect(
            try runGoMain(
                """
                handler(change())
                report()
                value.show(replace())
                report()
                pointer.grow(repoint())
                report()
                shown.show(reshow())
                report()
                held.run(refield())
                report()
                list[0](relist())
                report()
                other[index](reindex())
                report()
                named["k"](rename())
                report()
                """,
                declarations: """
                    var trace []string

                    func note(s string) { trace = append(trace, s) }

                    func report() {
                        fmt.Println(trace)
                        trace = nil
                    }

                    type box struct{ n int }

                    func (b box) show(a int, s string)  { note(fmt.Sprint("show ", b.n, " ", a, " ", s)) }
                    func (b *box) grow(a int, s string) { note(fmt.Sprint("grow ", b.n, " ", a, " ", s)) }

                    type shower interface{ show(a int, s string) }

                    func older(a int, s string) { note(fmt.Sprint("older ", a, " ", s)) }
                    func newer(a int, s string) { note(fmt.Sprint("newer ", a, " ", s)) }

                    var handler = older

                    func change() (int, string) { note("change"); handler = newer; return 1, "x" }

                    var value = box{1}

                    func replace() (int, string) { note("replace"); value = box{2}; return 1, "x" }

                    var pointer = &box{1}

                    func repoint() (int, string) { note("repoint"); pointer = &box{2}; return 1, "x" }

                    var shown shower = box{1}

                    func reshow() (int, string) { note("reshow"); shown = box{2}; return 1, "x" }

                    type holder struct{ run func(int, string) }

                    var held = holder{older}

                    func refield() (int, string) { note("refield"); held.run = newer; return 1, "x" }

                    var list = []func(int, string){older, newer}

                    func relist() (int, string) { note("relist"); list[0] = newer; return 1, "x" }

                    var other = []func(int, string){older, newer}

                    var index = 0

                    func reindex() (int, string) { note("reindex"); index = 1; return 1, "x" }

                    var named = map[string]func(int, string){"k": older}

                    func rename() (int, string) { note("rename"); named["k"] = newer; return 1, "x" }
                    """)
                == """
                [change newer 1 x]
                [replace show 2 1 x]
                [repoint grow 2 1 x]
                [reshow show 2 1 x]
                [refield newer 1 x]
                [relist newer 1 x]
                [reindex newer 1 x]
                [rename newer 1 x]

                """)
        #expect(
            try runGoMain(
                """
                function()(pair())
                report()
                value().show(pair())
                report()
                pointer().grow(pair())
                report()
                pointer().show(pair())
                report()
                shown().show(pair())
                report()
                list[index()](pair())
                report()
                bound := box{5}.show
                bound(pair())
                report()
                box.show(triple())
                report()
                older(pair())
                fmt.Println(calls)
                """,
                declarations: """
                    var trace []string

                    func note(s string) { trace = append(trace, s) }

                    func report() {
                        fmt.Println(trace)
                        trace = nil
                    }

                    type box struct{ n int }

                    func (b box) show(a int, s string)  { note(fmt.Sprint("show ", b.n, " ", a, " ", s)) }
                    func (b *box) grow(a int, s string) { note(fmt.Sprint("grow ", b.n, " ", a, " ", s)) }

                    type shower interface{ show(a int, s string) }

                    func older(a int, s string) { note(fmt.Sprint("older ", a, " ", s)) }
                    func newer(a int, s string) { note(fmt.Sprint("newer ", a, " ", s)) }

                    var calls = 0

                    func pair() (int, string) { calls++; note("pair"); return 1, "x" }

                    func triple() (box, int, string) { note("triple"); return box{7}, 1, "x" }

                    func function() func(int, string) { note("function"); return older }

                    func value() box { note("value"); return box{3} }

                    func pointer() *box { note("pointer"); return &box{4} }

                    func shown() shower { note("shown"); return box{6} }

                    var list = []func(int, string){older, newer}

                    func index() int { note("index"); return 1 }
                    """)
                == """
                [function pair older 1 x]
                [value pair show 3 1 x]
                [pointer pair grow 4 1 x]
                [pointer pair show 4 1 x]
                [shown pair show 6 1 x]
                [index pair newer 1 x]
                [pair show 5 1 x]
                [triple show 7 1 x]
                8

                """)
    }

    /// The inner call is made where the `defer` or the `go` is, as the other
    /// arguments of a deferred call are; the call that takes its results waits.
    @Test func deferAndGoTakeTheResultsWhenTheStatementRuns() throws {
        #expect(
            try runGoMain(
                """
                b := box{3}
                p := &box{4}
                f := plain
                bound := b.show
                defer plain(pair())
                defer b.show(pair())
                defer p.grow(pair())
                defer f(pair())
                defer bound(pair())
                defer func(a int, s string) { fmt.Println("literal", a, s) }(pair())
                defer fmt.Println(pair())
                defer fmt.Printf(format())
                defer box.show(func() (box, int, string) { return box{9}, 1, "expression" }())
                b.n, p.n = 30, 40
                fmt.Println("body", calls)
                """,
                declarations: #"""
                    type box struct{ n int }

                    func (b box) show(a int, s string)  { fmt.Println("show", b.n, a, s) }
                    func (b *box) grow(a int, s string) { fmt.Println("grow", b.n, a, s) }

                    var calls = 0

                    func pair() (int, string)           { calls++; return calls, "p" }
                    func format() (string, string, int) { calls++; return "%s %d\n", "format", calls }
                    func plain(a int, s string)         { fmt.Println("plain", a, s) }
                    """#)
                == """
                body 8
                show 9 1 expression
                format 8
                7 p
                literal 6 p
                show 3 5 p
                plain 4 p
                grow 40 3 p
                show 3 2 p
                plain 1 p

                """)
        #expect(
            try runGoMain(
                """
                done := make(chan string)
                p := &box{4}
                go send(wait(done))
                fmt.Println(<-done)
                go p.send(wait(done))
                fmt.Println(<-done)
                f := send
                go f(wait(done))
                fmt.Println(<-done)
                go func(c chan string, n int, s string) { c <- fmt.Sprint("literal ", n, " ", s) }(wait(done))
                fmt.Println(<-done)
                limit := 10
                go func(c chan string, n int, s string) { c <- fmt.Sprint("captures ", n+limit, " ", s) }(wait(done))
                fmt.Println(<-done, calls)
                """,
                declarations: """
                    type box struct{ n int }

                    func (b *box) send(c chan string, n int, s string) { c <- fmt.Sprint("method ", b.n, " ", n, " ", s) }

                    var calls = 0

                    func wait(c chan string) (chan string, int, string) { calls++; return c, calls, "w" }

                    func send(c chan string, n int, s string) { c <- fmt.Sprint("func ", n, " ", s) }
                    """)
                == "func 1 w\nmethod 4 2 w\nfunc 3 w\nliteral 4 w\ncaptures 15 w 5\n")
    }

    /// An import under another name, a type declared in the function, an
    /// alias, and a literal that captures what the call around it uses.
    @Test func everyPassSeesTheResults() throws {
        #expect(
            try runModule([
                (
                    "main.go",
                    #"""
                    package main

                    import (
                        f "fmt"
                        text "strings"
                    )

                    func pair() (int, string) { return 7, "seven" }

                    func times() (string, int) { return "ab", 2 }

                    func main() {
                        type local struct {
                            n int
                            s string
                        }
                        type same = local
                        build := func(n int, s string) local { return local{n, s} }
                        again := func(n int, s string) same { return same{n + 1, s} }
                        f.Println(build(pair()), again(pair()))
                        f.Printf("%T %v\n", again(pair()), text.Repeat(times()))
                        base := 10
                        add := func(n int, s string) int { base += n; return base + len(s) }
                        next := func() (int, string) { base++; return base, "next" }
                        f.Println(add(pair()), base)
                        f.Println(add(next()), base)
                        nested := func() int { return add(next()) + add(pair()) }
                        f.Println(nested(), base)
                        f.Println(f.Sprint(pair()), f.Sprint(next()))
                    }
                    """#
                ),
            ])
                == """
                {7 seven} {8 seven}
                main.local abab
                22 17
                40 36
                164 81
                7seven 82next

                """)
    }

    /// Between the packages of a module, with imports under other names and
    /// a dot import: a function, a method, an interface, a variable that holds a
    /// function, and a variadic parameter of another package.
    @Test func theResultsCrossPackages() throws {
        #expect(
            try runModule([
                (
                    "main.go",
                    #"""
                    package main

                    import (
                        f "fmt"
                        str "strings"

                        "example/m/lib"
                        . "example/m/util"
                    )

                    type point = lib.Point

                    func show(p point, err error) string { return f.Sprintf("%v %v", p, err) }

                    func format() (string, string, int) { return "%s %d\n", "format", 3 }

                    func main() {
                        s := lib.New()
                        f.Println(s.Put(lib.Pair()))
                        f.Println(s.Put(lib.Pair()))
                        f.Println(lib.Describe(s.Get("k")))
                        f.Println(lib.Describe(s.Get("missing")))
                        var g lib.Getter = s
                        f.Println(lib.Describe(g.Get("k")))
                        f.Println(g.Put(lib.Pair()))
                        f.Println(lib.Sum(lib.Triple()))
                        f.Println(lib.Sum(lib.Pair()))
                        f.Println(lib.Sum(lib.Sum(lib.Triple())))
                        f.Println(lib.Hook(lib.Pair()))
                        f.Println(Report(lib.New()))
                        f.Println(Show(lib.Origin()))
                        f.Println(show(lib.Origin()))
                        f.Println(str.Repeat(lib.Pair()))
                        f.Printf(format())
                        label, total := lib.Sum(lib.Triple())
                        f.Println(label, total)
                        put := s.Put
                        f.Println(put(lib.Pair()))
                        get := (*lib.Store).Get
                        f.Println(lib.Describe(get(s, "k")))
                        func() {
                            defer f.Println(lib.Sum(lib.Triple()))
                            k := 3
                            add := func(key string, n int) int { k += n; return k + len(key) }
                            f.Println(add(lib.Pair()), k)
                        }()
                    }
                    """#
                ),
                (
                    "lib/lib.go",
                    """
                    package lib

                    import "fmt"

                    type Store struct {
                        data map[string]int
                    }

                    type Getter interface {
                        Get(key string) (int, bool)
                        Put(key string, value int) (int, bool)
                    }

                    func New() *Store { return &Store{data: map[string]int{}} }

                    func (s *Store) Get(key string) (int, bool) {
                        v, ok := s.data[key]
                        return v, ok
                    }

                    func (s *Store) Put(key string, value int) (int, bool) {
                        old, ok := s.data[key]
                        s.data[key] = value
                        return old, ok
                    }

                    func Pair() (string, int) { return "k", 7 }

                    func Triple() (string, int, int) { return "t", 1, 2 }

                    func Describe(value int, ok bool) string { return fmt.Sprint("value=", value, " ok=", ok) }

                    func Sum(label string, values ...int) (string, int) {
                        total := 0
                        for _, v := range values {
                            total += v
                        }
                        return label, total
                    }

                    var Hook = func(key string, value int) string { return fmt.Sprint("hook:", key, "=", value) }

                    type Point struct{ X, Y int }

                    func Origin() (Point, error) { return Point{1, 2}, nil }
                    """
                ),
                (
                    "util/util.go",
                    """
                    package util

                    import (
                        f "fmt"

                        l "example/m/lib"
                    )

                    func Report(s *l.Store) string {
                        s.Put(l.Pair())
                        return f.Sprint(l.Describe(s.Get("k"))) + " " + f.Sprint(l.Sum(l.Triple()))
                    }

                    func Show(p l.Point, err error) string { return f.Sprintf("%v %T %v", p, p, err) }
                    """
                ),
            ])
                == """
                0 false
                7 true
                value=7 ok=true
                value=0 ok=false
                value=7 ok=true
                7 true
                t 3
                k 7
                t 3
                hook:k=7
                value=7 ok=true t3
                {1 2} lib.Point <nil>
                {1 2} <nil>
                kkkkkkk
                format 3
                t 3
                7 true
                value=7 ok=true
                11 10
                t 3

                """)
    }

    /// Twelve calls inside each other, each passing two results on: what a
    /// compiler built without optimization must manage on the stack of a test.
    @Test func forwardingNestsDeeply() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println(step(step(step(step(step(step(step(step(step(step(step(step(start())))))))))))))
                n, s := step(step(step(step(step(step(step(step(step(step(step(step(start()))))))))))))
                fmt.Println(n, s)
                """,
                declarations: """
                    func start() (int, string)               { return 0, "" }
                    func step(n int, s string) (int, string) { return n + 1, s + "." }
                    """)
                == "12 ............\n12 ............\n")
    }

    /// An operand, an element, an index, a condition, one value of a list:
    /// Go wants one value there and says so, where to take the first result
    /// would drop the others without a word.
    @Test func aCallOfSeveralResultsIsRefusedWhereOneValueIsWanted() {
        #expect(
            firstError("fmt.Println(two() + 1)", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:13: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError("fmt.Println(-two())", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:14: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError("fmt.Println([]int{two()})", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:19: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                p := &[]int{two()}
                fmt.Println(p)
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:13: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                m := map[int]int{}
                fmt.Println(m[two()])
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:15: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                m := map[string]int{"k": two()}
                fmt.Println(m)
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:26: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                x := point{x: two()}
                fmt.Println(x)
                """,
                declarations: """
                    func two() (int, string) { return 1, "a" }

                    type point struct{ x int }
                    """)
                == "7:15: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                s := []int{1, 2}
                fmt.Println(s[two():])
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:15: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                if two() == 1 {
                }
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:4: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                switch two() {
                case 1:
                }
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:8: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                for _, v := range list() {
                    fmt.Println(v)
                }
                """,
                declarations: "func list() ([]int, string) { return nil, \"a\" }")
                == "5:19: multiple-value list() (value of type ([]int, string)) in single-value context")
        #expect(
            firstError("fmt.Println(list()[0])", declarations: "func list() ([]int, string) { return nil, \"a\" }")
                == "5:13: multiple-value list() (value of type ([]int, string)) in single-value context")
        #expect(
            firstError("fmt.Println(value().x)", declarations: """
                    type point struct{ x int }

                    func value() (point, string) { return point{}, "a" }
                    """)
                == "7:13: multiple-value value() (value of type (point, string)) in single-value context")
        #expect(
            firstError("fmt.Println(value().get())", declarations: """
                    type point struct{ x int }

                    func (p point) get() int { return p.x }

                    func value() (point, string) { return point{}, "a" }
                    """)
                == "9:13: multiple-value value() (value of type (point, string)) in single-value context")
        #expect(
            firstError("fmt.Println(function()())", declarations: "func function() (func() int, string) { return nil, \"a\" }")
                == "5:13: multiple-value function() (value of type (func() int, string)) in single-value context")
        #expect(
            firstError(
                """
                c := make(chan int, 1)
                c <- two()
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:6: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                x := make([]int, two())
                fmt.Println(x)
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:18: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                x := []int{}
                x = append(x, two())
                fmt.Println(x)
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:15: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                x := int(two())
                fmt.Println(x)
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:10: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError("fmt.Println(string(two()))", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:20: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError("fmt.Println(n)", declarations: """
                    func two() (int, string) { return 1, "a" }

                    var n = two()
                    """)
                == "5:9: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError("fmt.Println(f())", declarations: """
                    func two() (int, string) { return 1, "a" }
                    func f() (int, int)      { return two(), 1 }
                    """)
                == "4:35: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError("take(two(), 1)", declarations: """
                    func two() (int, string)   { return 1, "a" }
                    func take(n int, s string) {}
                    """)
                == "6:6: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError("take(1, two())", declarations: """
                    func two() (int, string)   { return 1, "a" }
                    func take(n int, s string) {}
                    """)
                == "6:9: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                #"""
                fmt.Printf("%d %s\n", two())
                """#,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:23: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError("fmt.Println(\"values\", two())", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:23: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError("many(two()...)", declarations: """
                    func two() (int, string) { return 1, "a" }
                    func many(xs ...int)     {}
                    """)
                == "6:1: cannot use ... with 2-valued two()")
        #expect(
            firstError(
                """
                x := append(list()...)
                fmt.Println(x)
                """,
                declarations: "func list() ([]int, int) { return nil, 2 }")
                == "5:6: cannot use ... with 2-valued list()")
        #expect(
            firstError("fmt.Println(strconv.Atoi(\"5\") + 1)", imports: ["fmt", "strconv"])
                == "6:13: multiple-value strconv.Atoi() (value of type (int, interface{...})) in single-value context")
        #expect(
            firstError(
                """
                b := box{}
                fmt.Println(b.both() + 1)
                """,
                declarations: """
                    type box struct{}

                    func (b box) both() (int, string) { return 1, "a" }
                    """)
                == "8:13: multiple-value both() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                var s shower
                fmt.Println(s.both() == 1)
                """,
                declarations: "type shower interface{ both() (int, string) }")
                == "6:13: multiple-value both() (value of type (int, string)) in single-value context")
        #expect(
            firstError("fmt.Println(box.both(box{}) + 1)", declarations: """
                    type box struct{}

                    func (b box) both() (int, string) { return 1, "a" }
                    """)
                == "7:13: multiple-value box.both() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                h := holder{}
                fmt.Println(h.run() + 1)
                """,
                declarations: "type holder struct{ run func() (int, string) }")
                == "6:13: multiple-value run() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                list := []func() (int, string){two}
                fmt.Println(list[0]() + 1)
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:13: multiple-value function() (value of type (int, string)) in single-value context")
        #expect(
            firstError("fmt.Println(func() (int, string) { return 1, \"a\" }() + 1)")
                == "5:13: multiple-value function() (value of type (int, string)) in single-value context")
        #expect(
            firstError("fmt.Println(named() * 2)", declarations: "func named() (q, r int) { return 1, 2 }")
                == "5:13: multiple-value named() (value of type (int, int)) in single-value context")
        #expect(
            firstError(
                """
                var n int
                n = two()
                fmt.Println(n)
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:5: multiple-value two() (value of type (int, string)) in single-value context")
        #expect(
            firstError(
                """
                f := two
                n := f()
                fmt.Println(n)
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:6: multiple-value f() (value of type (int, string)) in single-value context")
        #expect(
            firstError("fmt.Println(one())", declarations: """
                    func two() (int, string) { return 1, "a" }
                    func one() int           { return two() }
                    """)
                == "4:35: too many return values")
    }

    /// Too many results, too few, or one of another type than its parameter:
    /// the error is at the inner call, as Go has it. A builtin that takes one
    /// argument reports the count where the call to it begins.
    @Test func resultsThatDoNotFitAreReportedWhereGoReportsThem() {
        #expect(
            firstError("take(two())", declarations: """
                    func two() (int, string) { return 1, "a" }
                    func take(n int)         {}
                    """)
                == "6:6: too many arguments in call to take")
        #expect(
            firstError("take(two())", declarations: """
                    func two() (int, string)           { return 1, "a" }
                    func take(n int, s string, b bool) {}
                    """)
                == "6:6: not enough arguments in call to take")
        #expect(
            firstError("take(two())", declarations: """
                    func two() (int, string) { return 1, "a" }
                    func take(a, b string)   {}
                    """)
                == "6:6: cannot use int as string value in argument to take")
        #expect(
            firstError("take(two())", declarations: """
                    func two() (int, string) { return 1, "a" }
                    func take(a, b int)      {}
                    """)
                == "6:6: cannot use string as int value in argument to take")
        #expect(
            firstError("box{}.take(two())", declarations: """
                    func two() (int, string) { return 1, "a" }

                    type box struct{}

                    func (b box) take(n int) {}
                    """)
                == "9:12: too many arguments in call to take")
        #expect(
            firstError("box{}.take(two())", declarations: """
                    func two() (int, string) { return 1, "a" }

                    type box struct{}

                    func (b box) take(n int, s string, b2 bool) {}
                    """)
                == "9:12: not enough arguments in call to take")
        #expect(
            firstError(
                """
                var t taker
                t.take(two())
                """,
                declarations: """
                    func two() (int, string) { return 1, "a" }

                    type taker interface{ take(n int, s string, b bool) }
                    """)
                == "8:8: wrong number of arguments in call to take")
        #expect(
            firstError(
                """
                f := func(a string, b int) {}
                f(two())
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:3: cannot use int as string value in argument to f")
        #expect(
            firstError("func(a int) {}(two())", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:16: wrong number of arguments in function literal call")
        #expect(
            firstError("func(a, b int) {}(two())", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:19: cannot use string as int value")
        #expect(
            firstError("many(two())", declarations: """
                    func two() (int, string) { return 1, "a" }
                    func many(xs ...string)  {}
                    """)
                == "6:6: cannot use int as string value in argument to many")
        #expect(
            firstError("many(two())", declarations: """
                    func two() (int, string)    { return 1, "a" }
                    func many(n int, xs ...int) {}
                    """)
                == "6:6: cannot use string as int value in argument to many")
        #expect(
            firstError("many(two())", declarations: """
                    func two() (int, string)                         { return 1, "a" }
                    func many(n int, s string, b bool, xs ...string) {}
                    """)
                == "6:6: not enough arguments in call to many")
        #expect(
            firstError("fmt.Printf(two())", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:12: cannot use int as string value")
        #expect(
            firstError(
                """
                s := fmt.Sprintf(two())
                fmt.Println(s)
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:18: cannot use int as string value")
        #expect(
            firstError("fmt.Fprintln(two())", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:14: cannot use int as *os.File value")
        #expect(
            firstError("fmt.Println(strings.Repeat(two()))", imports: ["fmt", "strings"],
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:28: cannot use int as string value")
        #expect(
            firstError("fmt.Println(strings.ToUpper(two()))", imports: ["fmt", "strings"],
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:29: wrong number of arguments in call to strings.ToUpper")
        #expect(
            firstError("fmt.Println(strconv.Itoa(two()))", imports: ["fmt", "strconv"],
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:26: wrong number of arguments in call to strconv.Itoa")
        #expect(
            firstError(
                """
                x := append(list())
                fmt.Println(x)
                """,
                declarations: "func list() ([]int, string) { return nil, \"a\" }")
                == "5:13: cannot use string as int value")
        #expect(
            firstError("fmt.Println(len(two()))", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:13: invalid argument count for len")
        #expect(
            firstError("fmt.Println(cap(two()))", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:13: invalid argument count for cap")
        #expect(
            firstError("panic(two())", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:1: panic takes exactly one argument")
        #expect(
            firstError("close(two())", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:1: close takes exactly one argument")
        #expect(
            firstError("fmt.Println(copy(three()))", declarations: "func three() ([]int, []int, int) { return nil, nil, 1 }")
                == "5:13: copy takes exactly two arguments")
        #expect(
            firstError("missing(two())", declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:1: undefined: missing")
        #expect(
            firstError(
                """
                x := 5
                x(two())
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "6:1: invalid operation: cannot call non-function x (variable of type int)")
        #expect(
            firstError(
                """
                unused := 1
                fmt.Println(two() + 1)
                """,
                declarations: "func two() (int, string) { return 1, \"a\" }")
                == "5:1: declared and not used: unused")
    }
}
