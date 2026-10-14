/// Type switches, `switch v := x.(type) { case T: ... }`.
///
/// A type switch is the `switch` of the tree: its expression is the guard
/// `x.(type)`, a type assertion to a type no program can name that carries
/// the name the switch binds, and the entries of its clauses are types. It
/// is checked and lowered with the machinery of a type assertion: each type
/// of a clause is asked of the operand, in the order of the source, as an
/// assertion with `, ok` is.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change. Where this dialect words a message its own way, the test
/// says so, and the place is still Go's. How `gofmt` writes a type switch is
/// compared with Go's in `GoControlFlowGofmtTests`.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go type switches")
struct GoTypeSwitchTests: GoTestHarness {

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

    /// Every kind of type is a case: predeclared and named types, pointers,
    /// slices, maps, arrays, channels, function types, and interface types, which
    /// match whatever implements them. The first clause that matches is taken.
    @Test func aClauseMatchesTheDynamicType() throws {
        #expect(
            try runGoMain(
                """
                values := []any{nil, 1, "s", true, byte(7), celsius(30), []int{1, 2}, map[string]int{"a": 1},
                    point{1, 2}, &point{3, 4}, errors.New("boom"), &failure{4}, square{3}, &circle{2},
                    func(n int) int { return n * 2 }, handler(func(n int) int { return n + 1 }),
                    make(chan int, 5), [2]int{8, 9}, []string{"x"}}
                for _, v := range values {
                    fmt.Println(classify(v))
                }
                """,
                imports: ["errors", "fmt"],
                declarations: """
                    type point struct{ x, y int }
                    type shape interface{ area() int }
                    type square struct{ side int }
                    func (s square) area() int { return s.side * s.side }
                    type circle struct{ r int }
                    func (c *circle) area() int { return 3 * c.r * c.r }
                    type failure struct{ code int }
                    func (f *failure) Error() string { return fmt.Sprint("code ", f.code) }
                    type celsius int
                    type handler func(int) int

                    func classify(x any) string {
                        switch v := x.(type) {
                        case nil:
                            return "nil"
                        case int:
                            return fmt.Sprint("int ", v+1)
                        case string:
                            return "string " + v
                        case bool:
                            if v {
                                return "true"
                            }
                            return "false"
                        case byte:
                            return fmt.Sprint("byte ", v)
                        case celsius:
                            return fmt.Sprint("celsius ", int(v))
                        case []int:
                            return fmt.Sprint("slice ", len(v))
                        case map[string]int:
                            return fmt.Sprint("map ", len(v))
                        case point:
                            return fmt.Sprint("point ", v.x, v.y)
                        case *point:
                            return fmt.Sprint("*point ", v.x)
                        case error:
                            return "error " + v.Error()
                        case shape:
                            return fmt.Sprint("shape ", v.area())
                        case func(int) int:
                            return fmt.Sprint("func ", v(2))
                        case handler:
                            return fmt.Sprint("handler ", v(3))
                        case chan int:
                            return fmt.Sprint("chan ", cap(v))
                        case [2]int:
                            return fmt.Sprint("array ", v[1])
                        case interface{ String() string }:
                            return "stringer " + v.String()
                        default:
                            return fmt.Sprintf("other %T", v)
                        }
                    }
                    """)
                == """
                nil
                int 2
                string s
                true
                byte 7
                celsius 30
                slice 2
                map 1
                point 1 2
                *point 3
                error boom
                error code 4
                shape 9
                shape 12
                func 4
                handler 4
                chan 5
                array 9
                other []string

                """)
    }

    /// In a clause of one type the name the switch binds has that type; in a
    /// clause of several types, of `nil`, and in the `default` it has the type of
    /// the operand. A switch need not bind a name, and `default` may come first.
    @Test func theNameHasTheTypeOfItsClause() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Println(kind(1), kind("a"), kind(nil), kind(errors.New("e")), kind(2 > 1))
                var x any = "hello"
                switch v := x.(type) {
                case int, string:
                    fmt.Printf("%T %v\n", v, v)
                default:
                    fmt.Printf("default %T\n", v)
                }
                switch v := x.(type) {
                default:
                    fmt.Printf("default %T %v\n", v, v)
                case int:
                    fmt.Println(v + 1)
                }
                var e error
                switch v := e.(type) {
                case nil:
                    fmt.Println("nil error", v == nil)
                }
                """#,
                imports: ["errors", "fmt"],
                declarations: """
                    func kind(x any) string {
                        switch x.(type) {
                        case int, string:
                            return "basic"
                        case nil:
                            return "nil"
                        case error:
                            return "error"
                        }
                        return "other"
                    }
                    """)
                == """
                basic basic nil error other
                string hello
                default string hello
                nil error true

                """)
    }

    /// The header is that of any `switch`: an initializer, whose variables
    /// last for the statement, before the guard. The operand is evaluated once.
    @Test func theOperandIsReadOnceAndMayHaveAnInitializer() throws {
        #expect(
            try runGoMain(
                """
                f := func() any { fmt.Println("once"); return 3 }
                switch y := f(); v := y.(type) {
                case int:
                    fmt.Println(v+1, y)
                }
                switch y := f(); y.(type) {
                case string:
                    fmt.Println("string")
                default:
                    fmt.Println("default")
                }
                switch f().(type) {
                }
                """)
                == "once\n4 3\nonce\ndefault\nonce\n")
    }

    /// `case nil` matches the interface value that holds nothing. A nil
    /// pointer in an interface has a type, and matches the case of that type.
    @Test func aNilPointerInAnInterfaceIsNoNil() throws {
        #expect(
            try runGoMain(
                """
                var p *point
                var x any = p
                switch v := x.(type) {
                case nil:
                    fmt.Println("nil")
                case *point:
                    fmt.Println("*point", v == nil)
                }
                var y any
                switch y.(type) {
                case nil:
                    fmt.Println("nil")
                default:
                    fmt.Println("default")
                }
                """,
                declarations: "type point struct{ x, y int }")
                == "*point true\nnil\n")
    }

    /// On an interface with methods, a type and the pointer to it are two
    /// cases, and each matches what was stored.
    @Test func aValueAndAPointerReceiverAreToldApart() throws {
        #expect(
            try runGoMain(
                """
                for _, x := range []I{A{}, &A{}, &B{}} {
                    switch x.(type) {
                    case A:
                        fmt.Println("A")
                    case *A:
                        fmt.Println("*A")
                    case *B:
                        fmt.Println("*B")
                    }
                }
                """,
                declarations: """
                    type A struct{}
                    type B struct{}
                    func (a A) M() {}
                    func (b *B) M() {}
                    type I interface{ M() }
                    """)
                == "A\n*A\n*B\n")
    }

    /// The name is a variable like any other: assigned, addressed, hidden by
    /// the name it was made from, and gone after the switch. A clause is a scope.
    @Test func theNameIsAVariableOfItsClause() throws {
        #expect(
            try runGoMain(
                """
                var x any = 5
                switch x := x.(type) {
                case int:
                    x++
                    fmt.Println(x)
                }
                fmt.Println(x)
                switch v := x.(type) {
                case int:
                    p := &v
                    *p = 9
                    fmt.Println(v)
                }
                switch v := x.(type) {
                case int:
                    var boxed any = v + 1
                    switch w := boxed.(type) {
                    case int:
                        fmt.Println(v, w)
                    }
                }
                """)
                == "6\n5\n9\n5 6\n")
        #expect(
            firstError(
                """
                var x any = 1
                switch v := x.(type) {
                case int:
                    _ = v
                default:
                }
                fmt.Println(v)
                """)
                == "11:13: undefined: v")
    }

    /// A function literal in a clause captures the variable of that clause,
    /// of that execution of the switch: each pass of a loop has its own.
    @Test func aLiteralCapturesTheNameOfItsClause() throws {
        #expect(
            try runGoMain(
                """
                var fs []func() int
                for _, x := range []any{1, 2, "abc"} {
                    switch v := x.(type) {
                    case int:
                        fs = append(fs, func() int { return v * 10 })
                    case string:
                        fs = append(fs, func() int { v += "!"; return len(v) })
                    }
                }
                for _, f := range fs {
                    fmt.Println(f(), f())
                }
                """)
                == "10 10\n20 20\n4 5\n")
    }

    /// `break` leaves the type switch and not the loop around it; a type
    /// switch in a function that calls itself, and over the elements of a list.
    @Test func switchesWorkInLoopsAndRecursion() throws {
        #expect(
            try runGoMain(
                """
                var x any = 1
                for i := 0; i < 3; i++ {
                    switch x.(type) {
                    case int:
                        if i == 1 {
                            break
                        }
                        fmt.Println("int", i)
                    }
                }
                describe(1, []any{2, "x"}, "s")
                list := &node{1, &node{"two", &node{3, nil}}}
                sum := 0
                for n := list; n != nil; n = n.next {
                    switch v := n.val.(type) {
                    case int:
                        sum += v
                    case string:
                        sum += len(v)
                    }
                }
                fmt.Println(sum)
                """,
                declarations: """
                    type node struct {
                        val  any
                        next *node
                    }
                    func describe(vs ...any) {
                        for i, v := range vs {
                            switch t := v.(type) {
                            case int:
                                fmt.Println(i, "int", t)
                            case []any:
                                fmt.Println(i, "nested", len(t))
                                describe(t...)
                            default:
                                fmt.Println(i, "?")
                            }
                        }
                    }
                    """)
                == "int 0\nint 2\n0 int 1\n1 nested 2\n0 int 2\n1 ?\n2 ?\n7\n")
    }

    /// A type a function declares is a case in that function, apart from a
    /// type of the same name in another; an alias is the type it stands for.
    @Test func typesDeclaredInFunctionsAndAliasesAreCases() throws {
        #expect(
            try runGoMain(
                #"""
                type pair struct{ a, b int }
                type number = int
                var values = []any{pair{1, 2}, 7, other()}
                for _, x := range values {
                    switch v := x.(type) {
                    case pair:
                        fmt.Println("pair", v.a+v.b)
                    case number:
                        fmt.Printf("%T %d\n", v, v)
                    default:
                        fmt.Printf("%T\n", v)
                    }
                }
                """#,
                declarations: """
                    func other() any {
                        type pair struct{ name string }
                        var x any = pair{"z"}
                        switch p := x.(type) {
                        case pair:
                            return p
                        }
                        return nil
                    }
                    """)
                == "pair 3\nint 7\nmain.pair\n")
    }

    /// The name is one variable to Go however many clauses there are: it is
    /// unused when no clause reads it, and reported where the switch declares it.
    @Test func aNameNoClauseUsesIsUnused() throws {
        #expect(
            firstError(
                """
                var x any = 1
                switch v := x.(type) {
                case int:
                    fmt.Println("int")
                case string:
                }
                """)
                == "6:8: v declared and not used")
        #expect(
            firstError(
                """
                var x any = 1
                switch y := x.(type) {
                }
                """)
                == "6:8: y declared and not used")
        #expect(
            try runGoMain(
                """
                var x any = 1
                switch v := x.(type) {
                case string:
                case int:
                    fmt.Println(v)
                }
                """)
                == "1\n")
    }

    /// Go refuses a type that two cases list, a second `nil`, and a type that
    /// no value of the operand's interface can have because it lacks a method.
    @Test func aTypeComesOnceAndMustBePossible() {
        #expect(
            firstError(
                """
                var x any = 1
                switch x.(type) {
                case int, int:
                }
                """)
                == "7:11: duplicate case int in type switch\n\tmain.go:7:6: previous case")
        #expect(
            firstError(
                """
                var x any = 1
                switch x.(type) {
                case []int:
                case string:
                case []int:
                }
                """)
                == "9:6: duplicate case []int in type switch\n\tmain.go:7:6: previous case")
        #expect(
            firstError(
                """
                var x any = 1
                switch x.(type) {
                case nil:
                case nil:
                }
                """)
                == "8:6: duplicate case nil in type switch\n\tmain.go:7:6: previous case")
        #expect(
            firstError(
                """
                var x error
                switch x.(type) {
                case int:
                }
                """)
                == "7:6: impossible type switch case: int\n\tx (variable of interface type error) cannot have dynamic type int (missing method Error)")
        #expect(
            firstError(
                """
                var x I
                switch x.(type) {
                case *T:
                case T:
                }
                """,
                declarations: """
                    type I interface{ M() }
                    type T struct{}
                    func (t *T) M() {}
                    """)
                == "10:6: impossible type switch case: T\n\tx (variable of interface type I) cannot have dynamic type T (method M has pointer receiver)")
        #expect(
            firstError(
                """
                var x any = 1
                switch x.(type) {
                case missing:
                }
                """)
                == "7:6: undefined: missing")
    }

    /// `fallthrough` has no place in a type switch, the guard none outside
    /// the header of a switch, and the operand is a value of an interface type.
    /// Go names the operand in that last message; here it is named by its type.
    @Test func whatATypeSwitchRefuses() {
        #expect(
            firstError(
                """
                var x any = 1
                switch x.(type) {
                case int:
                    fallthrough
                case string:
                }
                """)
                == "8:5: cannot fallthrough in type switch")
        #expect(
            firstError(
                """
                var x any = 1
                _ = x.(type)
                """)
                == "6:5: invalid syntax tree: use of .(type) outside type switch")
        #expect(
            firstError(
                """
                x := 1
                switch x.(type) {
                case int:
                }
                """)
                == "6:8: x (variable of type int) is not an interface")
        #expect(
            firstError(
                """
                var x any = 1
                switch x.(type) {
                default:
                default:
                }
                """)
                == "8:1: multiple defaults (first at main.go:7:1)")
        #expect(
            goMainDiagnostic(
                """
                var x any = 1
                switch v, w := x.(type) {
                }
                """)
                == "cannot use := as value")
    }

    /// A module of three packages. The cases of the root name types of the
    /// others through the package's name, another name the file gives it, and a dot
    /// import, an alias among them; the name the switch binds is `time`, which the
    /// file may use because it imports that package as `stdtime`; and a package that
    /// is not the root binds a name it also has at its top level, which is the
    /// package's again after the switch. Go prints the same.
    @Test func casesNameTypesOfOtherPackagesByWhateverTheFileCallsThem() throws {
        let packages = [
            GoPackageSource(
                importPath: "example/m",
                sources: [GoSourceFile(path: "/m/main.go", text: #"""
                package main

                import (
                    f "fmt"
                    "example/m/shapes"
                    sh "example/m/shapes"
                    . "example/m/v2"
                    stdtime "time"
                )

                type local = shapes.Square

                func classify(x any) string {
                    type pair struct{ a, b int }
                    var time any = pair{1, 2}
                    if x == nil {
                        x = time
                    }
                    switch time := x.(type) {
                    case shapes.Square:
                        return f.Sprint("Square ", time.Side)
                    case *sh.Circle:
                        return f.Sprint("*Circle ", time.R)
                    case sh.Unit, shapes.Shape:
                        return f.Sprintf("%T", time)
                    case pair:
                        return f.Sprint("pair ", time.a+time.b)
                    case Request:
                        return "request " + time.Path
                    case Handler:
                        return "handler " + time(Request{"/h"})
                    case func() stdtime.Time:
                        return "clock"
                    case error, interface{ String() string }:
                        return "library interface"
                    }
                    return "other"
                }

                func other() string {
                    type pair struct{ a string }
                    var x any = pair{"z"}
                    switch p := x.(type) {
                    case pair:
                        return p.a
                    }
                    return "?"
                }

                func main() {
                    var k local = shapes.Square{4}
                    values := []any{k, &sh.Circle{2}, sh.Unit(3), nil, Request{"/x"},
                        Handler(func(r Request) string { return r.Path + "!" }), func() stdtime.Time { return stdtime.Now() }, 5, f.Errorf("e")}
                    for _, v := range values {
                        f.Println(classify(v))
                    }
                    f.Println(other())
                    f.Println(shapes.Describe(shapes.Square{2}), shapes.Describe(&shapes.Circle{1}),
                        shapes.Describe(shapes.Unit(7)), shapes.Describe(nil), shapes.Describe("s"))
                    f.Println(shapes.Count(4))

                    var hits []func() string
                    for _, v := range values {
                        switch v := v.(type) {
                        case shapes.Shape:
                            hits = append(hits, func() string { return f.Sprint("area ", v.Area()) })
                        case local2:
                            hits = append(hits, func() string { return "never" })
                        }
                    }
                    for _, hit := range hits {
                        f.Println(hit())
                    }
                }

                type local2 struct{}
                """#)]),
            GoPackageSource(
                importPath: "example/m/shapes",
                sources: [GoSourceFile(path: "/m/shapes/shapes.go", text: #"""
                package shapes

                import "fmt"

                type Shape interface{ Area() int }

                type Square struct{ Side int }

                func (s Square) Area() int { return s.Side * s.Side }

                type Circle struct{ R int }

                func (c *Circle) Area() int { return 3 * c.R * c.R }

                type Kind = Square

                type Unit int

                var v = 100

                // Describe switches on types of its own package, and binds a name the
                // package also has at its top level.
                func Describe(x any) string {
                    switch v := x.(type) {
                    case nil:
                        return "nothing"
                    case Square:
                        return fmt.Sprint("square ", v.Side)
                    case *Circle:
                        return fmt.Sprint("circle ", v.R)
                    case Shape:
                        return fmt.Sprint("shape ", v.Area())
                    case Unit:
                        return fmt.Sprint("unit ", int(v))
                    }
                    return fmt.Sprint("other ", v)
                }

                func Count(limit Unit) (total int) {
                outer:
                    for i := range limit {
                        for j := range 3 {
                            if j > int(i) {
                                continue outer
                            }
                            total += j
                        }
                    }
                    return total
                }
                """#)]),
            GoPackageSource(
                importPath: "example/m/v2",
                sources: [GoSourceFile(path: "/m/v2/api.go", text: #"""
                package api

                type Request struct{ Path string }

                type Handler func(Request) string
                """#)]),
        ]
        let executable = try GoCompiler.compile(packages: packages, root: "example/m")
        var output = ""
        try GoVirtualMachine().run(executable) { output += $0 }
        #expect(
            output
                == """
                Square 4
                *Circle 2
                shapes.Unit
                pair 3
                request /x
                handler /h!
                clock
                other
                library interface
                z
                square 2 circle 1 unit 7 nothing other 100
                7
                area 16
                area 12

                """)
    }

    /// With a `default` and clauses that all return, nothing is missing
    /// after a type switch; without one, a `return` is.
    @Test func aTypeSwitchEndsAFunctionAsASwitchDoes() throws {
        #expect(
            try runGoMain("fmt.Println(f(1), f(\"s\"))", declarations: """
                    func f(x any) int {
                        switch x.(type) {
                        case int:
                            return 1
                        default:
                            return 2
                        }
                    }
                    """)
                == "1 2\n")
        #expect(
            firstError("fmt.Println(f(1))", declarations: """
                    func f(x any) int {
                        switch x.(type) {
                        case int:
                            return 1
                        }
                    }
                    """)
                == "8:1: missing return")
    }
}
