/// Struct types that are written out where a value is: the literal of a
/// struct without a name (`struct{ a int }{1}`), slices and maps of them,
/// which is how a table of test cases is written, and `struct{}{}`, the
/// element of a set and of a signal.
///
/// Two such types with the same fields are one type, and each is assignable
/// to and comparable with a named type of that structure. A struct value
/// carries the name of its type in the VM, so a value that crosses from one
/// to the other is written again under the name of its new type.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go struct types written in expressions")
struct GoAnonymousStructTests: GoTestHarness {

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

    /// The type of a literal may be a struct type written where the literal is.
    @Test func aLiteralOfAStructTypeWrittenInPlace() throws {
        #expect(
            try runGoMain(
                #"""
                p := struct{ a int }{1}
                q := struct {
                    name string
                    n    int
                }{"x", 2}
                q.n++
                p = struct{ a int }{a: 7}
                r := &struct{ a, b int }{1, 2}
                r.a = 5
                var zero struct{ a int }
                fmt.Println(p, q, p.a, q.name, *r, r.b, zero)
                fmt.Printf("%v %+v %#v %T %T\n", p, q, p, q, r)
                """#)
                == """
                {7} {x 3} 7 x {5 2} 2 {0}
                {7} {name:x n:3} struct { a int }{a:7} struct { name string; n int } *struct { a int; b int }

                """)
        #expect(
            try runGoMain(
                #"""
                x := struct {
                    a int
                    b struct{ c string }
                }{1, struct{ c string }{"z"}}
                y := []struct{ a []int }{{[]int{1}}, {a: nil}}
                fmt.Printf("%v %+v %T\n", x, x, x)
                fmt.Printf("%v %+v\n", y, y)
                """#)
                == """
                {1 {z}} {a:1 b:{c:z}} struct { a int; b struct { c string } }
                [{[1]} {[]}] [{a:[1]} {a:[]}]

                """)
    }

    /// A slice of a struct type written in place, with a literal for each case
    /// that leaves the type out: the table of a table-driven test.
    @Test func tablesOfCases() throws {
        #expect(
            try runGoMain(
                #"""
                tests := []struct {
                    name string
                    in   []int
                    want int
                    fail bool
                }{
                    {"empty", nil, 0, false},
                    {"one", []int{1}, 1, false},
                    {name: "many", in: []int{1, 2, 3}, want: 6},
                    {name: "bad", fail: true},
                }
                for _, tt := range tests {
                    sum := 0
                    for _, v := range tt.in {
                        sum += v
                    }
                    fmt.Println(tt.name, sum == tt.want, tt.fail)
                }
                fmt.Printf("%v %+v %T\n", tests[1], tests[2], tests)
                """#)
                == """
                empty true false
                one true false
                many true false
                bad true true
                {one [1] 1 false} {name:many in:[1 2 3] want:6 fail:false} []struct { name string; in []int; want int; fail bool }

                """)
        #expect(
            try runGoMain(
                """
                colors := map[string]struct{ r, g, b int }{"red": {255, 0, 0}, "blue": {b: 255}}
                byPair := map[struct{ a, b int }]string{{1, 2}: "x"}
                ps := []*struct{ n int }{{1}, {2}}
                ps[0].n = 9
                fmt.Println(colors["red"].r, colors, byPair[struct{ a, b int }{1, 2}], ps[0].n, ps[1].n)
                for _, c := range []struct {
                    in  string
                    out int
                }{{"a", 1}, {"b", 2}} {
                    fmt.Print(c.in, c.out, " ")
                }
                fmt.Println(cases[0].ok, len(cases))
                """,
                declarations: """
                    var cases = []struct {
                        name string
                        ok   bool
                    }{
                        {"first", true},
                        {name: "second"},
                    }
                    """)
                == "255 map[blue:{0 0 255} red:{255 0 0}] x 9 2\na1 b2 true 2\n")
    }

    /// `struct{}{}` is the one value of the struct without fields: the element
    /// of a set, and what a channel carries when only the arrival matters.
    @Test func theEmptyStruct() throws {
        #expect(
            try runGoMain(
                #"""
                set := map[string]struct{}{"z": {}}
                set["a"] = struct{}{}
                set["b"] = struct{}{}
                _, ok := set["a"]
                _, no := set["q"]
                done := make(chan struct{})
                go func() { done <- struct{}{} }()
                v := <-done
                var e struct{}
                units := []struct{}{{}, {}}
                fmt.Println(len(set), ok, no, set, v, struct{}{} == v, e == v, len(units))
                fmt.Printf("%T %T %v %+v\n", v, set, struct{}{}, units)
                """#)
                == """
                3 true false map[a:{} b:{} z:{}] {} true true 2
                struct {} map[string]struct {} {} [{} {}]

                """)
    }

    /// A struct type without a name is a type like any other: of a field, a
    /// parameter, a result, an element, and what a channel carries.
    @Test func structTypesInSignaturesAndFields() throws {
        #expect(
            try runGoMain(
                #"""
                var c conf
                c.addr.host = "h"
                c.addr.port = 80
                c.tags = append(c.tags, struct{ k, v string }{"a", "b"})
                o := origin()
                c2 := conf{addr: struct {
                    host string
                    port int
                }{"x", 1}}
                ch := make(chan struct{ id int }, 1)
                ch <- struct{ id int }{7}
                x := new(struct{ a int })
                x.a = 3
                fmt.Printf("%+v\n", c)
                fmt.Println(show(o), show(struct{ x, y int }{3, 4}), o.x, c2.addr, c2.tags == nil, (<-ch).id, *x)
                """#,
                declarations: """
                    type conf struct {
                        addr struct {
                            host string
                            port int
                        }
                        tags []struct{ k, v string }
                    }

                    func origin() struct{ x, y int } { return struct{ x, y int }{1, 2} }

                    func show(p struct{ x, y int }) string { return fmt.Sprint(p.x, p.y) }
                    """)
                == "{addr:{host:h port:80} tags:[{k:a v:b}]}\n1 2 3 4 1 {x 1} true 7 {3}\n")
    }

    /// Identity is by the fields. A value of a struct type without a name is
    /// assigned to a named type of that structure and back, compared with one, and
    /// converted to one; in an interface each keeps the type it had.
    @Test func structTypesOfTheSameFieldsAreOneType() throws {
        #expect(
            try runGoMain(
                #"""
                x := struct{ a int }{1}
                var t T = x
                x = t
                m := map[T]string{t: "t"}
                u := T(x)
                v := struct{ a int }(t)
                fmt.Printf("%v %+v %T %T\n", x, x, x, t)
                fmt.Println(x == t, x == struct{ a int }{1}, t == T{1}, t == x, t != x)
                fmt.Println(m[T{1}], m[x], u == t, v == x)
                fmt.Printf("%T %T\n", u, v)
                """#,
                declarations: "type T struct{ a int }")
                == """
                {1} {a:1} struct { a int } main.T
                true true true true false
                t t true true
                main.T struct { a int }

                """)
        #expect(
            try runGoMain(
                #"""
                var a struct{ x int }
                var b struct{ x int }
                a.x = 1
                b = a
                var i interface{} = a
                _, ok := i.(struct{ x int })
                _, no := i.(struct{ y int })
                var j interface{} = struct{ x, y int }{1, 2}
                _, isPt := j.(pt)
                var k interface{} = pt{1, 2}
                fmt.Println(a == b, ok, no, isPt, j == k, j == interface{}(struct{ x, y int }{1, 2}))
                fmt.Printf("%T %T\n", i, k)
                """#,
                declarations: "type pt struct{ x, y int }")
                == "true true false false false true\nstruct { x int } main.pt\n")
        #expect(
            try runGoMain(
                #"""
                a := point{1, 2}
                b := pt(a)
                c := struct{ x, y int }(b)
                d := point(c)
                var i interface{} = b
                _, isPoint := i.(point)
                _, isPt := i.(pt)
                fmt.Println(a, b, c, d, d == a, pt(a) == b, isPoint, isPt)
                fmt.Printf("%T %T %T %T\n", a, b, c, d)
                """#,
                declarations: """
                    type point struct{ x, y int }
                    type pt struct{ x, y int }
                    """)
                == """
                {1 2} {1 2} {1 2} {1 2} true true false true
                main.point main.pt struct { x int; y int } main.point

                """)
    }

    /// A literal of a struct type written out is no operand before a block, so
    /// it stands in the clause of a `for`, an `if`, or a `switch`.
    @Test func inTheHeaderOfAStatement() throws {
        #expect(
            try runGoMain(
                """
                if v := (struct{ a int }{1}); v.a == 1 {
                    fmt.Println("one")
                }
                for _, v := range []struct{ a int }{{1}, {2}} {
                    fmt.Print(v.a)
                }
                switch x := (struct{ a int }{2}); x.a {
                case 2:
                    fmt.Println(" two")
                }
                """)
                == "one\n12 two\n")
    }

    /// What Go reports for a literal of a struct type written in place.
    @Test func mistakesInStructLiterals() {
        #expect(
            firstError(
                """
                x := struct{ a int }{a: 1, b: 2}
                fmt.Println(x)
                """)
                == "5:28: unknown field b in struct literal of type struct{a int}")
        #expect(
            firstError(
                """
                x := struct{ a int }{1, 2}
                fmt.Println(x)
                """)
                == "5:25: too many values in struct literal of type struct{a int}")
        #expect(
            firstError(
                """
                x := struct{ a, b int }{1}
                fmt.Println(x)
                """)
                == "5:26: too few values in struct literal of type struct{a int; b int}")
        #expect(
            firstError(
                """
                var t named = struct{ b int }{1}
                fmt.Println(t)
                """,
                declarations: "type named struct{ a int }")
                == "5:15: cannot use struct{b int}{…} (value of type struct{b int}) as named value in variable declaration")
        #expect(
            firstError(
                """
                x := struct{ a int }{1}
                y := struct{ b int }{1}
                fmt.Println(x == y)
                """)
                == "7:18: invalid operation: x == y (mismatched types struct{a int} and struct{b int})")
        #expect(
            firstError("fmt.Println(other(point{1, 2}))", declarations: """
                    type point struct{ x, y int }
                    type other struct{ a, b int }
                    """)
                == "6:19: cannot convert point{…} (value of struct type point) to type other")
        #expect(
            firstError(
                """
                x := struct{ a int }
                fmt.Println(x)
                """)
                == "5:6: struct{a int} (type) is not an expression")
    }
}
