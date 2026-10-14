/// The builtins `new`, `min`, `max`, and `clear`.
///
/// `new(T)` is a pointer to a new variable of type `T` that holds its zero
/// value, made by the reserved call that makes the variable of `&T{...}`.
/// `min` and `max` take one or more operands of one ordered type, which here
/// is an integer or a string type, and are a constant when their operands
/// are. `clear` empties a map and zeroes the elements of a slice, in one
/// instruction of the VM (`$clear`).
///
/// Each is a name Go predeclares and a program may give another meaning.
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports; a message
/// this dialect words without the operand's description is pinned as it is.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go builtins new, min, max, and clear")
struct GoNewMinMaxClearTests: GoTestHarness {

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

    /// A pointer to a new variable, of every kind of type, that is the type's
    /// zero value until it is assigned.
    @Test func newMakesAZeroVariableOfAnyType() throws {
        #expect(
            try runGoMain(
                #"""
                a := new(int)
                b := new(string)
                c := new(bool)
                d := new(point)
                e := new([]int)
                f := new(map[string]int)
                g := new([3]int)
                h := new(*point)
                i := new(list)
                j := new(table)
                k := new(fn)
                l := new(interface{})
                m := new(error)
                n := new(byte)
                o := new(chan int)
                p := new(struct{ a, b int })
                q := new(func(int) string)
                fmt.Println(*a, *b == "", *c, *d, *e == nil, *f == nil, *g, *h == nil, *i == nil, *j == nil, *k == nil, *l, *m, *n, *o == nil, *p, *q == nil)
                fmt.Printf("%T %T %T %T %T %T %T %T %T %T %T %T\n", a, b, d, e, f, g, h, i, n, o, p, q)
                *a = 5
                d.X = 3
                *e = append(*e, 1)
                g[1] = 7
                *h = d
                p.b = 2
                fmt.Println(*a, *d, *e, *g, (*h).X, *p)
                """#,
                declarations: """
                    type point struct{ X, Y int }
                    type list []int
                    type table map[string]int
                    type fn func() int
                    """)
                == """
                0 true false {0 0} true true [0 0 0] true true true true <nil> <nil> 0 true {0 0} true
                *int *string *main.point *[]int *map[string]int *[3]int **main.point *main.list *uint8 *chan int *struct { a int; b int } *func(int) string
                5 {3 0} [1] [0 7 0] 3 {0 2}

                """)
    }

    /// Every evaluation makes a variable of its own, which lives while a
    /// pointer reaches it: a list built in a loop has a node for each turn.
    @Test func eachNewIsAnotherVariable() throws {
        #expect(
            try runGoMain(
                """
                var head *node
                for i := 0; i < 3; i++ {
                    head = push(head, i)
                }
                for n := head; n != nil; n = n.next {
                    fmt.Print(n.val, " ")
                }
                ptrs := []*int{}
                for i := 0; i < 3; i++ {
                    p := new(int)
                    *p = i
                    ptrs = append(ptrs, p)
                }
                fresh := func() *int { return new(int) }
                x, y := fresh(), fresh()
                *x = 1
                t := new(node)
                t.val = 1
                u := *t
                u.val = 2
                fmt.Println(*ptrs[0], *ptrs[1], *ptrs[2], *x, *y, x == y, new(int) != new(int), t.val, u.val)
                var i interface{} = new(int)
                p, ok := i.(*int)
                fmt.Println(ok, *p, *new(interface{}) == nil)
                """,
                declarations: """
                    type node struct {
                        val  int
                        next *node
                    }

                    func push(head *node, v int) *node {
                        n := new(node)
                        n.val = v
                        n.next = head
                        return n
                    }
                    """)
                == "2 1 0 0 1 2 1 0 false true 1 2\ntrue 0 true\n")
    }

    /// The smallest and the largest of one or more operands of an ordered type.
    /// Every operand is evaluated, once, in order.
    @Test func minAndMaxOfIntegersAndStrings() throws {
        #expect(
            try runGoMain(
                #"""
                fmt.Println(min(3, 1, 2), max(3, 1, 2), min(7), max(-1, -5))
                a, b := 4, 9
                fmt.Println(min(a, b), max(a, b), min(a, 6, b), max(a, 6, b), min(a, a))
                var x byte = 200
                var y byte = 100
                fmt.Println(min(x, y), max(x, y), min(x, 50), max(y, 250))
                fmt.Printf("%T %T %T\n", min(x, y), min(a, b), max(1, 2))
                s, t := "pear", "apple"
                fmt.Println(min(s, t), max(s, t), min("b", "a", "c"), max(s, "zebra"), min("", s))
                """#)
                == "1 3 7 -1\n4 9 4 9 4\n100 200 50 250\nuint8 int int\napple pear a zebra \n")
        #expect(
            try runGoMain(
                """
                calls := 0
                f := func(v int) int { calls++; fmt.Print("f", v, " "); return v }
                fmt.Println(min(f(3), f(1), f(2)), calls)
                fmt.Println(max(f(1), f(3), f(2)), calls)
                m := map[string]int{"a": 1, "b": 5}
                fmt.Println(min(m["a"], m["b"], len(m)), max(len("abc"), cap([]int{1})))
                """)
                == "f3 f1 f2 1 3\nf1 f3 f2 3 6\n1 3\n")
    }

    /// The operands that have a type share it, and a constant among them takes
    /// it. Of constants alone the result is a constant, which fits where one
    /// fits.
    @Test func minAndMaxOfNamedTypesAndConstants() throws {
        #expect(
            try runGoMain(
                #"""
                var c celsius = 30
                n := name("m")
                o := name("z")
                const k = min(1, 2) + max(3, 4)
                var bb byte = min(200, 300)
                fmt.Println(min(c, 20), max(c, big), min(limit, 3), max(limit, 30), k, bb)
                fmt.Println(min(n, o), max(n, o), min(n, "a"), max("zz", n))
                fmt.Printf("%T %T %T %T %T\n", min(c, 20), max(limit, 3), max(big, c), min(n, "a"), max("zz", n))
                """#,
                declarations: """
                    type celsius int
                    type name string

                    const limit = 10
                    const big celsius = 40
                    """)
                == """
                20 40 3 30 5 200
                m z a zz
                main.celsius int main.celsius main.name main.name

                """)
    }

    /// A map keeps its identity and loses its entries; a slice keeps its length
    /// and every element of it becomes the zero value, in the array it shares.
    @Test func clearEmptiesAMapAndZeroesASlice() throws {
        #expect(
            try runGoMain(
                """
                m := map[string]int{"a": 1, "b": 2}
                alias := m
                clear(m)
                fmt.Println(len(m), len(alias), m)
                m["c"] = 3
                s := []int{1, 2, 3, 4}
                t := s[1:3]
                clear(t)
                var nm map[string]int
                var ns []int
                clear(nm)
                clear(ns)
                fmt.Println(alias, s, t, len(t), cap(t), nm == nil, ns == nil)
                """)
                == "0 0 map[]\nmap[c:3] [1 0 0 4] [0 0] 2 3 true true\n")
        #expect(
            try runGoMain(
                #"""
                ps := []point{{1, 2}, {3, 4}}
                clear(ps)
                st := set{{1, 2}: true}
                clear(st)
                ls := list{"a", "b"}
                clear(ls)
                pp := []*point{{1, 2}}
                clear(pp)
                bs := []byte("abc")
                clear(bs[:2])
                arr := [3]int{1, 2, 3}
                clear(arr[:])
                fmt.Println(ps, len(st), pp[0] == nil, bs, arr)
                fmt.Printf("%q\n", ls)
                mm := map[string][]int{"a": {1}}
                defer func() { fmt.Println(len(mm)) }()
                defer clear(mm)
                done := make(chan bool)
                shared := map[string]int{"a": 1}
                go func() {
                    clear(shared)
                    done <- true
                }()
                <-done
                fmt.Println(len(shared), len(mm))
                """#,
                declarations: """
                    type point struct{ X, Y int }
                    type set map[point]bool
                    type list []string
                    """)
                == "[{0 0} {0 0}] 0 true [0 0 99] [0 0 0]\n[\"\" \"\"]\n0 1\n0\n")
    }

    /// `new`, `min`, `max`, and `clear` are predeclared, not reserved: a
    /// function or a variable of the program with one of the names is what the
    /// name means there.
    @Test func aProgramMayUseTheNamesItself() throws {
        #expect(
            try runGoMain("fmt.Println(max(1, 2), min(1, 2, 3), clear(1), new(2))", declarations: """
                    func max(a, b int) int {
                        if a > b {
                            return a
                        }
                        return b
                    }

                    func min(values ...int) int { return len(values) }

                    func clear(x int) int { return x + 1 }

                    func new(x int) int { return x * 2 }
                    """)
                == "2 3 2 4\n")
        #expect(
            try runGoMain(
                """
                min := func(a, b int) int { return a * b }
                max := 10
                fmt.Println(min(3, 4), max)
                """)
                == "12 10\n")
    }

    /// The mistakes Go reports in a call of one of them.
    @Test func whatTheBuiltinsRefuse() {
        #expect(
            firstError("fmt.Println(new())")
                == "5:13: invalid operation: not enough arguments for new() (expected 1, found 0)")
        #expect(
            firstError("fmt.Println(new(int, 5))")
                == "5:13: invalid operation: too many arguments for new(int, 5) (expected 1, found 2)")
        #expect(
            firstError("fmt.Println(new(5))")
                == "5:17: 5 is not a type")
        #expect(
            firstError("fmt.Println(new(undefined))")
                == "5:17: undefined: undefined")
        #expect(
            firstError(
                """
                x := 5
                fmt.Println(new(x))
                """)
                == "6:17: x is not a type")
        #expect(
            firstError("fmt.Println(min())")
                == "5:13: invalid operation: not enough arguments for min() (expected 1, found 0)")
        #expect(
            firstError("fmt.Println(min(1, \"a\"))")
                == "5:20: invalid argument: mismatched types untyped int (previous argument) and untyped string (type of \"a\")")
        #expect(
            firstError(
                """
                x, y := 1, byte(2)
                fmt.Println(min(x, y))
                """)
                == "6:20: invalid argument: mismatched types int (previous argument) and byte (type of y)")
        #expect(
            firstError(
                """
                x := 1
                s := "a"
                fmt.Println(min(x, s))
                """)
                == "7:20: invalid argument: mismatched types int (previous argument) and string (type of s)")
        #expect(
            firstError(
                """
                var s []int
                fmt.Println(min(s, s))
                """)
                == "6:17: invalid argument: s (variable of type []int) cannot be ordered")
        #expect(
            firstError(
                """
                p := new(int)
                fmt.Println(min(p, p))
                """)
                == "6:17: invalid argument: p (variable of type *int) cannot be ordered")
        #expect(
            firstError(
                """
                x := []int{1, 2}
                fmt.Println(min(x...))
                """)
                == "6:13: invalid operation: invalid use of ... with built-in min")
        #expect(
            firstError(
                """
                var a A
                var b B
                fmt.Println(max(a, b))
                """,
                declarations: """
                    type A int
                    type B int
                    """)
                == "8:20: invalid argument: mismatched types A (previous argument) and B (type of b)")
        #expect(
            firstError("clear()")
                == "5:1: invalid operation: not enough arguments for clear() (expected 1, found 0)")
        #expect(
            firstError(
                """
                x := 5
                clear(x)
                """)
                == "6:7: invalid argument: cannot clear x (variable of type int): argument must be (or constrained by) map or slice")
        #expect(
            firstError(
                """
                var a [3]int
                clear(a)
                """)
                == "6:7: invalid argument: cannot clear a (variable of type [3]int): argument must be (or constrained by) map or slice")
        #expect(
            firstError(
                """
                s := "abc"
                clear(s)
                """)
                == "6:7: invalid argument: cannot clear s (variable of type string): argument must be (or constrained by) map or slice")
        #expect(
            firstError(
                """
                m := map[string]int{}
                clear(m, m)
                """)
                == "6:1: invalid operation: too many arguments for clear(m, m) (expected 1, found 2)")
        #expect(
            goMainDiagnostic(
                """
                var b byte = max(300, 2)
                fmt.Println(b)
                """)
                == "constant 300 overflows byte")
        #expect(
            goMainDiagnostic(
                """
                var b byte = 1
                fmt.Println(min(b, 300))
                """)
                == "constant 300 overflows byte")
        #expect(
            firstError("fmt.Println(min(true, false))")
                == "5:17: invalid argument: true (untyped bool constant) cannot be ordered")
    }

    /// A builtin that is called for its value is no statement of its own, and
    /// nothing for `go` or `defer` to start: Go says so, with the call.
    @Test func aValueNothingTakes() {
        #expect(
            firstError("min(1, 2)")
                == "5:1: min(1, 2) (untyped int constant 1) is not used")
        #expect(
            firstError("new(int)")
                == "5:1: new(int) (value of type *int) is not used")
        #expect(
            firstError(
                """
                var s []int
                len(s)
                """)
                == "6:1: len(s) (value of type int) is not used")
        #expect(
            firstError(
                """
                var s []int
                append(s, 1)
                """)
                == "6:1: append(s, 1) (value of type []int) is not used")
        #expect(
            firstError("make([]int, 1)")
                == "5:1: make([]int, 1) (value of type []int) is not used")
        #expect(
            firstError("go min(1, 2)")
                == "5:4: go discards result of min(1, 2) (untyped int constant 1)")
        #expect(
            firstError("defer new(int)")
                == "5:7: defer discards result of new(int) (value of type *int)")
        #expect(
            firstError(
                """
                var s []int
                defer len(s)
                """)
                == "6:7: defer discards result of len(s) (value of type int)")
    }
}
