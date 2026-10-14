/// Untyped string and boolean constants, and the named types they take.
///
/// `"GET"` is a `Method` where a `Method` is wanted and `true` is a `Flag`,
/// as an untyped integer constant has long been a `byte`. The result of a
/// comparison is an untyped boolean too, whether or not its operands are
/// constants. A typed constant keeps its type. See `WordConstants.swift`.
///
/// What each program prints is what Go 1.24.5 prints for it. An error is
/// pinned by its message, which is worded as this dialect words such
/// messages and was compared with Go's when the test was written.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go constants that take a named type")
struct GoConstantTypeTests: GoTestHarness {

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

    /// In a declaration, an argument, a result, a composite literal, a map
    /// index, a channel send, an operand, and a `case`.
    @Test func aStringConstantTakesANamedStringType() throws {
        #expect(
            try runGoMain(
                #"""
                x, y := pair()
                bx := box{k: "boxed", s: "plain"}
                fmt.Println(name(A), name("b"), name("z"), kinds(), x, y, bx)
                var p *Kind = new(Kind)
                *p = "ptr"
                ch := make(chan Kind, 2)
                ch <- "one"
                ch <- B
                counts := map[Kind]int{"b": 2, A: 1}
                counts["c"]++
                fmt.Println(*p, <-ch, <-ch, bx.k == "boxed", bx.k+"!", counts, counts["b"], A == "a", "a" == A, B < "c")
                fmt.Printf("%T %T %T %v\n", A, x, bx.k+"!", []Kind{"lit", B})
                """#,
                declarations: """
                    type Kind string

                    const (
                        A Kind = "a"
                        B Kind = "b"
                    )

                    type box struct {
                        k Kind
                        s string
                    }

                    func name(k Kind) string {
                        switch k {
                        case A:
                            return "first"
                        case "b":
                            return "second"
                        }
                        return "none"
                    }

                    func kinds() []Kind      { return []Kind{A, "b", "c"} }
                    func pair() (Kind, Kind) { return "x", B }
                    """)
                == """
                first second none [a b c] x b {boxed plain}
                ptr one b true boxed! map[a:1 b:2 c:1] 2 true true true
                main.Kind main.Kind main.Kind [lit b]

                """)
    }

    /// An untyped string constant, and `+` of such, takes the type of a typed
    /// operand on either side; the result has that type, and its methods.
    @Test func constantExpressionsOfStringsKeepWhatTheyAre() throws {
        #expect(
            try runGoMain(
                #"""
                var s S = c
                t := c + d
                u := d + c
                var v T = c + "x"
                var a any = "lit" + s
                b := "pre" + s
                fmt.Println(s, t, u, v, a, b, d == c, c == d, len(c), len(d), joined, typed)
                fmt.Printf("%T %T %T %T %T %T %T %v\n", t, u, v, a, b, joined, typed, c)
                if s == "c" && "d" == d && s != "" {
                    fmt.Println("ok", s < "z", "a" < s)
                }
                s += "!"
                s = s + "?" + c
                var list = []S{c, "lit", d}
                fmt.Println(s, list, map[S]T{"k": "v", c: c})
                """#,
                declarations: """
                    type S string
                    type T string

                    const c = "c"
                    const d S = "d"
                    const joined = "a" + "b" + c
                    const typed S = joined + "!"

                    func (s S) String() string { return "<" + string(s) + ">" }
                    """)
                == """
                <c> <cd> <dc> cx <litc> <prec> false false 1 1 abc <abc!>
                main.S main.S main.T main.S main.S string main.S c
                ok true true
                <c!?c> [<c> <lit> <d>] map[<c>:c <k>:v]

                """)
        #expect(
            goMainDiagnostic(
                """
                var x string = "p"
                var s S = x
                fmt.Println(s)
                """,
                declarations: "type S string")
                == "cannot use x (variable of type string) as S value in variable declaration")
        #expect(
            goMainDiagnostic(
                """
                var b B = a
                fmt.Println(b)
                """,
                declarations: """
                    type A string
                    type B string

                    const a A = "a"
                    """)
                == #"cannot use a (constant "a" of string type A) as B value in variable declaration"#)
        #expect(
            goMainDiagnostic("fmt.Println(a + b)", declarations: """
                    type A string
                    type B string

                    const a A = "a"
                    const b B = "b"
                    """)
                == "invalid operation: a + b (mismatched types A and B)")
        #expect(
            goMainDiagnostic(
                """
                var s S = 5
                fmt.Println(s)
                """,
                declarations: "type S string")
                == "cannot use 5 (untyped int constant) as S value in variable declaration")
    }

    /// `true`, `false`, an untyped boolean constant, and the result of any
    /// comparison are untyped; a typed one keeps its type.
    @Test func aBooleanConstantTakesANamedBoolType() throws {
        #expect(
            try runGoMain(
                #"""
                var f Flag = yes
                g := yes && on
                h := on || false
                var i Flag = 3 > 2
                n := 5
                var j Flag = n > 3 && n < 9
                var k any = true && on
                fmt.Println(f, g, h, i, j, k, set(true), set(n == 5), !on, on == true, yes, never)
                fmt.Printf("%T %T %T %T %T %v\n", g, h, k, yes, never, f)
                if on && f {
                    fmt.Println("both")
                }
                var o Other = !yes
                flags := map[Flag]string{true: "t", false: "f"}
                fmt.Println(o, flags[n > 9], []Flag{true, n == 5, on})
                """#,
                declarations: """
                    type Flag bool
                    type Other bool

                    const yes = true
                    const on Flag = true
                    const never Flag = !yes || 1 > 2

                    func (f Flag) String() string {
                        if f {
                            return "ON"
                        }
                        return "OFF"
                    }

                    func set(f Flag) Flag { return !f }
                    """)
                == """
                ON ON ON ON ON ON OFF OFF OFF true true OFF
                main.Flag main.Flag main.Flag bool main.Flag ON
                both
                false f [ON ON ON]

                """)
        #expect(
            goMainDiagnostic(
                """
                var o Other = on
                fmt.Println(o)
                """,
                declarations: """
                    type Flag bool
                    type Other bool

                    const on Flag = true
                    """)
                == "cannot use on (constant of bool type Flag) as Other value in variable declaration")
        #expect(
            goMainDiagnostic(
                """
                b := true
                var f Flag = b
                fmt.Println(f)
                """,
                declarations: "type Flag bool")
                == "cannot use b (variable of type bool) as Flag value in variable declaration")
    }

    /// `len` of a constant string is a constant of type `int`: it names one
    /// and folds with others, and is no value of another type without a conversion.
    @Test func theLengthOfAConstantStringIsAConstant() throws {
        #expect(
            try runGoMain(
                #"""
                var wide uint64 = uint64(len("abc")) << 60
                fmt.Println(n, m, wide, n*2, len(word)+1, uint8(n)+249, big)
                fmt.Printf("%T %T %T\n", n, m, big)
                """#,
                declarations: """
                    const word = "héllo"
                    const n = len(word)
                    const m = len("ab") + n
                    const big = 1 << (len(word) * 10)
                    """)
                == "6 8 3458764513820540928 12 7 255 1152921504606846976\nint int int\n")
        #expect(
            goMainDiagnostic(
                """
                var small int8 = len("abc")
                fmt.Println(small)
                """)
                == "cannot use len(\"abc\") (constant 3 of type int) as int8 value in variable declaration")
        #expect(
            goMainDiagnostic("fmt.Println(uint8(len(\"abc\")) + 253)")
                == #"uint8(len("abc")) + 253 (constant 256 of type byte) overflows byte"#)
    }

    /// The length of an array is any constant expression of integers: a named
    /// constant of the package or of the function, operators, and `len` of a
    /// constant string. A variable of the name hides the constant.
    @Test func anArrayLengthIsAConstantExpression() throws {
        #expect(
            try runGoMain(
                #"""
                var a [n]int
                var b [2 * m]string
                c := [len("héllo")]byte{1}
                d := [...]int{1, 2, 3}
                var e [m - 1][n]bool
                var g grid
                g[3][2] = 7
                const k = 2
                var h [k << 2]int8
                var r rec
                r.name[7] = 'x'
                fmt.Println(len(a), len(b), len(c), len(d), len(e), len(e[0]), n, a, c, g, len(h), sum([m]int{1, 2, 3, 4}), fill(), r.name)
                fmt.Printf("%T %T %T %T %T\n", b, e, g, h, fill())
                {
                    const m = 2
                    var inner [m]int
                    m2 := [m * m]bool{true}
                    fmt.Println(len(inner), m2)
                }
                p := &[m]int{9}
                s := make([][n]int, 2)
                fmt.Println(p[0], len(s[1]), [1 + 1]int{5, 6} == [2]int{5, 6}, cap(make(chan [m]bool, n)))
                """#,
                declarations: """
                    const n = len("abc")
                    const m = 4

                    type grid [m][n]uint8

                    type rec struct {
                        name [2 * m]byte
                        next *[n]rec
                    }

                    func sum(a [m]int) (total int) {
                        for _, v := range a {
                            total += v
                        }
                        return
                    }

                    func fill() [n + 1]string { return [n + 1]string{"a", "b"} }
                    """)
                == """
                3 8 6 3 3 3 3 [0 0 0] [1 0 0 0 0 0] [[0 0 0] [0 0 0] [0 0 0] [0 0 7]] 8 10 [a b  ] [0 0 0 0 0 0 0 120]
                [8]string [3][3]bool main.grid [8]int8 [4]string
                2 [true false false false]
                9 3 true 3

                """)
        #expect(
            firstError(
                """
                var a [-1]int
                fmt.Println(a)
                """)
                == "5:8: invalid array length -1 (untyped int constant)")
        #expect(
            firstError(
                """
                var a [k]int
                fmt.Println(a)
                """,
                declarations: "const k = -2")
                == "5:8: invalid array length k (untyped int constant -2)")
        #expect(
            firstError(
                """
                m := 2
                var a [m]int
                fmt.Println(a, m)
                """,
                declarations: "const m = 4")
                == "6:8: invalid array length m")
        #expect(
            goMainDiagnostic(
                """
                var a [size()]int
                fmt.Println(a)
                """,
                declarations: "func size() int { return 3 }")
                == "invalid array length size()")
        #expect(
            goMainDiagnostic(
                """
                n := 3
                var a [n]int
                fmt.Println(a)
                """)
                == "invalid array length n")
    }

    /// `gofmt` gives the operators of a length the blanks Go's gives them,
    /// where a `*` would otherwise be the star of a pointer type.
    @Test func gofmtPrintsALengthAsAnExpression() throws {
        let messy = """
            package main
            import "fmt"
            const n=len("abc")
            const m  = 4
            type grid [m][n ]uint8
            type rec struct{
            name [2*m]byte
            next *[ n]rec
            values [n+1][m-1]map[string][m]int
            wide [2*m+1]*rec
            var2 [m*n*2]int
            }
            func sum(a [m]int,b [2*m+1]string)(total int){return len(a)+len(b)}
            func main(){
            var a [n]int
            var w [2*m+n]*int
            var z [ m*n ]*[n]int
            c:=[len("héllo")]byte{1}
            var h [m<<2]int8
            x:=[m*2]int{1,2}
            fmt.Println(a,c,h,x,[n+1]string{"a"},sum([m]int{},[2*m+1]string{}))
            }

            """
        let formatted = try GoFormatter.format(GoSourceFile(path: "main.go", text: messy))
        #expect(
            formatted
                == """
                package main

                import "fmt"

                const n = len("abc")
                const m = 4

                type grid [m][n]uint8
                type rec struct {
                \tname   [2 * m]byte
                \tnext   *[n]rec
                \tvalues [n + 1][m - 1]map[string][m]int
                \twide   [2*m + 1]*rec
                \tvar2   [m * n * 2]int
                }

                func sum(a [m]int, b [2*m + 1]string) (total int) { return len(a) + len(b) }
                func main() {
                \tvar a [n]int
                \tvar w [2*m + n]*int
                \tvar z [m * n]*[n]int
                \tc := [len("héllo")]byte{1}
                \tvar h [m << 2]int8
                \tx := [m * 2]int{1, 2}
                \tfmt.Println(a, c, h, x, [n + 1]string{"a"}, sum([m]int{}, [2*m + 1]string{}))
                }

                """)
        #expect(try GoFormatter.format(GoSourceFile(path: "main.go", text: formatted)) == formatted)
    }
}
