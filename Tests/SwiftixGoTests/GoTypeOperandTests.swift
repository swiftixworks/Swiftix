/// Types that are written where an expression stands: the target of a
/// conversion, in parentheses when it does not begin like an operand
/// (`(chan int)(nil)`, `(func())(nil)`, `(<-chan int)(c)`), and the operand of
/// `new` and `make`, which may be a name.
///
/// A conversion yields the value under its new type: `any(x)` and `error(nil)`
/// are interface values, a channel becomes one of its directions, and a
/// struct or an array converts to a type of the same structure.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go types written where an expression stands")
struct GoTypeOperandTests: GoTestHarness {

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

    /// Any type may stand in parentheses before the value it converts.
    @Test func aTypeInParenthesesIsAConversionTarget() throws {
        #expect(
            try runGoMain(
                #"""
                var c1 = (chan int)(nil)
                var c2 = (<-chan int)(make(chan int))
                var c3 = (chan<- int)(nil)
                var f1 = (func())(nil)
                var f2 = (func(int) int)(func(n int) int { return n + 1 })
                var f3 = (func(string) (int, error))(nil)
                var b = ([]byte)("abc")
                var m = (map[string]int)(nil)
                var p = (*point)(nil)
                var t = (T)(5)
                var s = []int(nil)
                var h = handler(func(s string) string { return s + "!" })
                var h2 = (handler)(nil)
                var n = names([]string{"a"})
                var n2 = ([]string)(n)
                var st = (string)(b)
                var in = (int)(t)
                fmt.Println(c1 == nil, c2 != nil, c3 == nil, f1 == nil, f2(1), f3 == nil, b, m == nil, p == nil, t, s == nil)
                fmt.Println(h("x"), h2 == nil, n, n2, st, in)
                fmt.Printf("%T %T %T %T %T %T %T\n", c1, c2, c3, f1, f2, f3, h)
                """#,
                declarations: """
                    type T int
                    type point struct{ x, y int }
                    type handler func(string) string
                    type names []string
                    type sizer interface{ Size() int }

                    func (p point) Size() int { return p.x + p.y }
                    """)
                == """
                true true true true 2 true [97 98 99] true true 5 true
                x! true [a] [a] abc 5
                chan int <-chan int chan<- int func() func(int) int func(string) (int, error) main.handler

                """)
        #expect(
            try runGoMain(
                #"""
                var p = (*int)(nil)
                var q = (**int)(nil)
                var r = (*[]int)(nil)
                var s = (*[3]int)(nil)
                var t = (*struct{ a int })(nil)
                var u = (*map[string]int)(nil)
                var v = (*func())(nil)
                var w = (*chan int)(nil)
                fmt.Println(p, q, r, s, t, u, v, w)
                fmt.Printf("%T %T %T %T %T %T %T %T\n", p, q, r, s, t, u, v, w)
                """#)
                == """
                <nil> <nil> <nil> <nil> <nil> <nil> <nil> <nil>
                *int **int *[]int *[3]int *struct { a int } *map[string]int *func() *chan int

                """)
    }

    /// A channel is converted to a channel of one direction as it is assigned
    /// to one, and a function type converts a function of that type.
    @Test func aChannelConvertsToItsDirections() throws {
        #expect(
            try runGoMain(
                """
                ch := make(chan int, 1)
                ro := (<-chan int)(ch)
                so := (chan<- int)(ch)
                so <- 5
                g := (func() func() int)(func() func() int { return func() int { return 7 } })
                fmt.Println(<-ro, g()(), (chan int)(nil) == nil)
                if c := (chan int)(nil); c == nil {
                    fmt.Println("nil")
                }
                """)
                == "5 7 true\nnil\n")
    }

    /// `any(x)`, `interface{}(x)`, `error(nil)`, and a conversion to a named
    /// interface hold the value with its type, as an assignment would.
    @Test func conversionsToInterfaceTypes() throws {
        #expect(
            try runGoMain(
                #"""
                x := 5
                var a interface{} = any(x)
                var e error = error(nil)
                var i = (interface{})(5)
                var j = interface{}("x")
                var k = any(point{1, 2})
                var z = sizer(point{3, 4})
                fmt.Println(a, e == nil, any(nil) == nil, any("s"), interface{}(nil), i, j, k, z.Size())
                fmt.Printf("%T %T %v %T %T\n", any(x), any(byte(1)), any([]int{1}), k, z)
                """#,
                declarations: """
                    type T int
                    type point struct{ x, y int }
                    type handler func(string) string
                    type names []string
                    type sizer interface{ Size() int }

                    func (p point) Size() int { return p.x + p.y }
                    """)
                == "5 true true s <nil> 5 x {1 2} 7\nint uint8 [1] main.point main.point\n")
    }

    /// Two struct types of the same fields, and two array types of the same
    /// elements, convert to each other whatever either is called.
    @Test func structsAndArraysConvertByStructure() throws {
        #expect(
            try runGoMain(
                #"""
                a := pair{1, 2}
                b := couple(a)
                c := struct{ x, y int }(b)
                v := vec([2]int{1, 2})
                w := [2]int(v)
                fmt.Println(a, b, c, pair(c) == a, v, w)
                fmt.Printf("%T %T %T %T %T\n", a, b, c, v, w)
                """#,
                declarations: """
                    type pair struct{ x, y int }
                    type couple struct{ x, y int }
                    type vec [2]int
                    """)
                == """
                {1 2} {1 2} {1 2} true [1 2] [1 2]
                main.pair main.couple struct { x int; y int } main.vec [2]int

                """)
    }

    /// The operand of `make` and of `new` is a type, which a name is one way
    /// to write.
    @Test func makeAndNewTakeANamedType() throws {
        #expect(
            try runGoMain(
                #"""
                n := make(names, 2, 4)
                t := make(table)
                t2 := make(table, 10)
                s := make(sig, 1)
                g := make(grid, 2)
                p := new(names)
                q := new(*table)
                n[0] = "a"
                t["x"] = 1
                t2["y"] = 2
                s <- struct{}{}
                g[0] = []int{1}
                fmt.Println(n, len(n), cap(n), t, t2, len(s), g, *p == nil, *q == nil)
                fmt.Printf("%T %T %T %T %T %T\n", n, t, s, g, p, q)
                """#,
                declarations: """
                    type names []string
                    type table map[string]int
                    type sig chan struct{}
                    type grid [][]int
                    """)
                == """
                [a ] 2 4 map[x:1] map[y:2] 1 [[1] []] true true
                main.names main.table main.sig main.grid *main.names **main.table

                """)
    }

    /// A type alone is no value, and a value converts only to a type it fits.
    @Test func whatIsNoConversion() {
        #expect(
            firstError("fmt.Println(error(T{1}))", declarations: "type T struct{ a int }")
                == "5:19: cannot convert T{…} (value of struct type T) to type error: T does not implement error (missing method Error)")
        #expect(
            firstError("fmt.Println((int)(\"x\"))")
                == "5:19: cannot convert \"x\" (untyped string constant) to type int")
        #expect(
            firstError(
                """
                x := (func())
                fmt.Println(x)
                """)
                == "5:6: (func()) (type) is not an expression")
        #expect(
            firstError("fmt.Println(chan int)")
                == "5:13: chan int (type) is not an expression")
        #expect(
            firstError(
                """
                x := make(undefined, 1)
                fmt.Println(x)
                """)
                == "5:11: undefined: undefined")
        #expect(
            firstError(
                """
                x := make(int, 1)
                fmt.Println(x)
                """)
                == "5:11: invalid argument: cannot make int; type must be slice, map, or channel")
        #expect(
            firstError(
                """
                x := make(T)
                fmt.Println(x)
                """,
                declarations: "type T struct{ a int }")
                == "5:11: invalid argument: cannot make T; type must be slice, map, or channel")
    }
}
