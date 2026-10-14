/// `==` and `!=` between an interface value and a value of a concrete type,
/// or of another interface type, and a `switch` on an interface with cases
/// of concrete types: the concrete operand is converted to the interface,
/// and two interface values are equal when they hold equal values of one
/// dynamic type.
///
/// What each program prints is what Go 1.24.5 prints for it, and each error
/// pinned with its place is the first one its compiler reports, copied
/// without change.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go interface comparisons")
struct GoInterfaceComparisonTests: GoTestHarness {

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

    /// An untyped constant has its default type, so an `int8` 5 is no 5; a
    /// struct, an array, a pointer, a channel, and a named type compare by
    /// value and type, from either side.
    @Test func anInterfaceComparesWithAConcreteValue() throws {
        #expect(
            try runGoMain(
                """
                var a any = 5
                fmt.Println(a == 5, 5 == a, a != 6, a == int8(5), a == 5.0, a == "5")
                var b any = int8(5)
                fmt.Println(b == 5, b == int8(5), int8(5) != b)
                var c any = 2.5
                fmt.Println(c == 2.5, c == float32(2.5))
                var r any = 'x'
                fmt.Println(r == 'x', r == 120, r == rune(120))
                type mine int
                var m any = mine(3)
                fmt.Println(m == 3, m == mine(3))
                type point struct{ x int }
                var p any = point{1}
                fmt.Println(p == point{1}, p == point{2}, p == struct{ x int }{1})
                var arr any = [2]int{1, 2}
                fmt.Println(arr == [2]int{1, 2}, arr == [2]int{1, 3}, arr == [3]int{1, 2, 0})
                ch := make(chan int)
                var ci any = ch
                ptr := &point{}
                var pi any = ptr
                fmt.Println(ci == ch, pi == ptr, pi == &point{})
                var t any = true
                fmt.Println(t == true, t == (1 < 2), t != false)
                is := func(x any) bool { return x == 3 }
                fmt.Println(is(3), is(int64(3)), is("3"))
                values := map[string]any{"k": 7}
                fmt.Println(values["k"] == 7, values["none"] == nil)
                """)
                == """
                true true true false false false
                false true false
                true false
                true false true
                false true
                true false false
                true false false
                true true false
                true true true
                true false false
                true true

                """)
    }

    /// `err == target` where `target` is a concrete error, and an `any` with an
    /// `error`; a `switch` on an error has cases of either kind.
    @Test func anErrorComparesWithTheValueItMayHold() throws {
        #expect(
            try runGoMain(
                """
                for n := 0; n < 4; n++ {
                    err := fail(n)
                    fmt.Println(n, err == errFirst, errFirst == err, err == valueError{2}, err != valueError{3}, err == io.EOF)
                    switch err {
                    case errFirst:
                        fmt.Println("first")
                    case valueError{2}:
                        fmt.Println("value")
                    case io.EOF:
                        fmt.Println("eof")
                    case nil:
                        fmt.Println("nil")
                    }
                }
                e := errors.New("x")
                var a any = e
                var none error
                var nothing any
                fmt.Println(a == e, e == a, none == nothing, nothing == none)
                """,
                imports: ["errors", "fmt", "io"],
                declarations: """
                    type codeError struct{ code int }

                    func (e *codeError) Error() string { return fmt.Sprint("code ", e.code) }

                    type valueError struct{ code int }

                    func (e valueError) Error() string { return "value" }

                    var errFirst = &codeError{1}

                    func fail(n int) error {
                        switch n {
                        case 1:
                            return errFirst
                        case 2:
                            return valueError{2}
                        case 3:
                            return io.EOF
                        }
                        return nil
                    }
                    """)
                == """
                0 false false false true false
                nil
                1 true true false true false
                first
                2 false false true true false
                value
                3 false false false true true
                eof
                true true true true

                """)
    }

    /// A case is converted to the interface, and the value of a switch that is
    /// no interface to the type of an interface case.
    @Test func aSwitchOnAnInterfaceHasConcreteCases() throws {
        #expect(
            try runGoMain(
                #"""
                for _, v := range []any{5, "s", 2.5, int8(5), nil} {
                    switch v {
                    case 4, 5:
                        fmt.Println("int")
                    case "s":
                        fmt.Println("string")
                    case 2.5:
                        fmt.Println("float")
                    case nil:
                        fmt.Println("nil")
                    default:
                        fmt.Printf("other %T\n", v)
                    }
                }
                var a any = 1
                x := 1
                switch x {
                case a:
                    fmt.Println("x is a")
                }
                switch 1 {
                case a:
                    fmt.Println("1 is a")
                }
                """#)
                == "int\nstring\nfloat\nother int8\nnil\nx is a\n1 is a\n")
    }

    /// Two interface values that hold values of one type that is not
    /// comparable panic, as Go's do; of two types, they are unequal.
    @Test func valuesOfATypeThatDoesNotCompareComparePanic() throws {
        #expect(
            try runGoMain(
                """
                var s1, s2 any = []int{1}, []int{1}
                guarded("slices", func() { fmt.Println(s1 == s2) })
                guarded("same", func() { fmt.Println(s1 != s1) })
                var m any = map[int]int{}
                guarded("map and int", func() { fmt.Println(m == 1, 1 == m) })
                var st any = struct{ s []int }{}
                guarded("struct", func() { fmt.Println(st == st) })
                var f any = func() {}
                guarded("func", func() { fmt.Println(f == f) })
                type list []int
                var l any = list{}
                guarded("named", func() { fmt.Println(l == l) })
                var arr any = [1][]int{}
                guarded("array", func() { fmt.Println(arr == 1, arr == arr) })
                """,
                declarations: #"""
                    func guarded(name string, f func()) {
                        defer func() {
                            r := recover()
                            fmt.Printf("%s: %v (%T)\n", name, r, r)
                        }()
                        f()
                    }
                    """#)
                == """
                slices: runtime error: comparing uncomparable type []int (runtime.errorString)
                same: runtime error: comparing uncomparable type []int (runtime.errorString)
                false false
                map and int: <nil> (<nil>)
                struct: runtime error: comparing uncomparable type struct { s []int } (runtime.errorString)
                func: runtime error: comparing uncomparable type func() (runtime.errorString)
                named: runtime error: comparing uncomparable type main.list (runtime.errorString)
                array: runtime error: comparing uncomparable type [1][]int (runtime.errorString)

                """)
    }

    /// A value of a type that is not comparable, an operand that does not fit
    /// the interface, and an order between interfaces.
    @Test func wrongComparisonsAreRefused() {
        #expect(
            firstError(
                """
                var a any = []int{1}
                fmt.Println(a == []int{1})
                """)
                == "6:18: invalid operation: a == []int{…} (slice can only be compared to nil)")
        #expect(
            firstError(
                """
                var a any = 1
                var s []int
                fmt.Println(a == s)
                """)
                == "7:18: invalid operation: a == s (slice can only be compared to nil)")
        #expect(
            firstError(
                """
                var a any = 1
                var f func()
                fmt.Println(a == f)
                """)
                == "7:18: invalid operation: a == f (func can only be compared to nil)")
        #expect(
            firstError(
                """
                var a any = 1
                var m map[int]int
                fmt.Println(m == a)
                """)
                == "7:13: invalid operation: m == a (map can only be compared to nil)")
        #expect(
            firstError(
                """
                var e error
                fmt.Println(e == 5)
                """)
                == "6:18: cannot convert 5 (untyped int constant) to type interface{Error() string}")
        #expect(
            firstError(
                """
                var e error
                fmt.Println(e == "x")
                """)
                == "6:18: cannot convert \"x\" (untyped string constant) to type interface{Error() string}")
        #expect(
            firstError(
                """
                var a any = 1
                fmt.Println(a < 2)
                """)
                == "6:13: invalid operation: a < 2 (operator < not defined on interface)")
        #expect(
            firstError(
                """
                var a any = 1
                fmt.Println(2 > a)
                """)
                == "6:17: invalid operation: 2 > a (operator > not defined on interface)")
        #expect(
            firstError(
                """
                var a any = 1
                fmt.Println(a <= int8(2))
                """)
                == "6:13: invalid operation: a <= int8(2) (operator <= not defined on interface)")
        #expect(
            firstError(
                """
                var a any = 1
                switch a {
                case []int{}:
                }
                fmt.Println()
                """)
                == "7:6: invalid case []int{} in switch on a (slice can only be compared to nil)")
        #expect(
            firstError(
                """
                var a any = 1
                var f func()
                switch a {
                case f:
                }
                fmt.Println()
                """)
                == "8:6: invalid case f in switch on a (func can only be compared to nil)")
        #expect(
            firstError(
                """
                var e error
                switch e {
                case 5:
                }
                fmt.Println()
                """)
                == "7:6: cannot convert 5 (untyped int constant) to type interface{Error() string}")
        #expect(
            firstError(
                """
                var a any = 1
                switch a {
                case 1, 1:
                }
                fmt.Println()
                """)
                == "7:9: duplicate case 1 (constant of type int) in expression switch\n\tmain.go:7:6: previous case")
        #expect(
            firstError(
                """
                var a any = 1
                switch a {
                case "x", "x":
                }
                fmt.Println()
                """)
                == "7:11: duplicate case \"x\" (constant of type string) in expression switch\n\tmain.go:7:6: previous case")
    }
}
